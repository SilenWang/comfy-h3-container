# 故障排查

## `PathchSageAttentionKJ` 报 `ModuleNotFoundError: No module named 'sageattention'`

**现象**：执行 i2v/t2v 工作流时，节点 137（`PathchSageAttentionKJ`）抛出 `ModuleNotFoundError`，日志里前面有 `Using sage attention mode: sageattn_qk_int8_pv_fp16_cuda`。

**根因**：镜像构建期的 SageAttention 源码安装失败，但被 `|| echo WARN` 容错吞掉，于是镜像「构建成功」却漏装了 `sageattention`（旧版 Dockerfile 用 `git clone` 拉源码，部分构建机会卡在 index-pack / 超时失败）。确认方式：

```bash
docker exec comfyui-h3 /opt/environments/python/comfyui/bin/pip show sageattention
```

**修复（无需重建镜像，推荐）**：在运行中的容器里现场编译安装 SageAttention v2.2.0：

```bash
pixi run fix-sage-attn                  # 等价于 bash scripts/install_sageattention.sh
# 自定义容器名：./scripts/install_sageattention.sh <容器名>
```

KJNodes 是在节点执行时才 import，装好后**不用重启 ComfyUI**，直接在 WebUI 重新 Queue 即可。

**兜底**：若暂时不想编译，可把 `PathchSageAttentionKJ` 的 `sage_attention` 模式从 `sageattn_qk_int8_pv_fp16_cuda` 改成 `auto`（需先 `pip install sageattention` 装 V1）或 `disabled`，工作流仍可跑通，只是失去注意力加速。

> 现版本 Dockerfile 已改用 codeload tarball + 重试来拉源码，并先装 PyPI V1 兜底、编译后校验 import，不会再出现「构建成功却漏装」的静默失败。

## 容器写不进 output / 模型列表为空

挂载目录不是以你自己的用户创建的：Docker 会以 root 创建不存在的 bind 源，容器内以 uid 1000 运行的 ComfyUI 读不到 / 写不进。先 `mkdir -p models output`（详见 [deployment.md](deployment.md#1-目录准备很重要)）。

## ComfyUI 跑完任务后内存 / 显存不释放，后续任务卡死

**现象**：任务跑完后 `docker stats` 的 MEM USAGE 居高不下、`nvidia-smi` 显存也不回落；连续跑几条不同工作流后，后面的任务长时间没进展，甚至容器里的进程被杀（OOM）。用 MCP 批量调用时尤其明显。

**根因**：**这不是 MCP 泄漏，是 ComfyUI 的缓存设计 + 容器内存上限**。

1. ComfyUI 跑完任务**不会释放**：模型留在显存（默认 smart memory「能留就留」），显存不够时也只是卸载到系统内存继续留着；节点中间结果走 RAM 压力缓存（默认阈值取系统内存的 active 10% / inactive 100%）；safetensors 默认 mmap 读进来的页缓存同样计入容器内存。官方唯一的释放口是 `POST /free {"unload_models":true,"free_memory":true}`（WebUI 的 **Free model and node cache** 按钮就是它）。
2. 于是跨模型族连续调用会层层堆积（H3 权重 ~37GB → Qwen-Edit 9.2GB 主模型 + 4.7GB 文本编码器 → SDXL 2×6.9GB），而 `docker-compose.yml` 的 `memory` 上限（默认 24G）远低于本仓库推荐的「32GB 起 / 64GB 稳」，撞上限后只能靠换页与回收活着 —— 表现就是「后面的任务卡死」。
3. 另一个放大器：ComfyUI 的动态显存会把主机内存**锁页**（pinned；检测到 cgroup 限制时预算是 `ram - 4GB`）。锁页内存内核既不能回收也不能换出，一撞上限就是 OOM kill —— 被杀的是 ComfyUI 就丢队列、是 MCP 进程就丢客户端会话，两种都表现为「卡死」。

### 已内置处置：容器内 `comfyui-idle-free` 守护（默认开启）

它在队列空闲（无 running / 无 pending）超过 `COMFYUI_IDLE_FREE_SECONDS` 秒（默认 60）后按顺序做四件事：

1. 记录 cgroup 内存明细（working set / anon / file / inactive_file / pinned）；
2. `POST /free {"unload_models":true,"free_memory":true}` 卸载模型、清节点缓存、清显存；
3. 若页缓存仍高于 `COMFYUI_IDLE_FREE_FILE_CACHE_MIN_MB`，对模型文件调 `posix_fadvise(DONTNEED)` **丢弃页缓存**；
4. （可选）长空闲后若 anon/pinned 仍高，`supervisorctl restart comfyui` 重启进程回收匿名/锁页内存（默认关闭）。

> **为什么第 3 步是必须的**：`/free` 不会动文件页缓存。实测在一个已空闲 11 小时的容器里手动 `/free`：
> 显存从 7.3GB 占用降到 0.5GB（`vram_free` 5.17GB → 11.94GB），但 `memory.stat` 的 `file` 一点没降，
> `docker stats` 的 MEM USAGE 也就「不释放」。本仓库的 Qwen-Edit 链路（9.22GB 主模型 + 4.68GB
> 文本编码器 + VAE/LoRA）读盘产生的页缓存恰好 ~15GB，和观测到的常驻占用吻合。这些页是干净的、
> 可回收的，但内核在没有内存压力时不会主动丢；24G 硬上限下必须显式丢。

队列不空就不释放，所以**连续批量任务不受影响**；也**不会打断正在跑的任务**：`/free` 只是给队列置 flag，由 ComfyUI 的 prompt worker 在循环里消费，正在执行的任务读不到它，最坏也只是「当前任务跑完才释放」。

```bash
pixi run mem-status                               # 看 cgroup 明细 + 显存 + 守护状态/日志（排查先跑这个）
pixi run free                                     # 手动立即释放：/free + 丢弃页缓存
docker exec -u root comfyui-h3 supervisorctl status comfyui-idle-free   # 应为 RUNNING
docker exec -u root comfyui-h3 tail -f /var/log/supervisor/comfyui-idle-free.log
```

**已经部署的旧容器不需要重建镜像**：`pixi run mem-install` 会把最新守护与页缓存脚本 `docker cp` 进容器并重启该守护（ComfyUI 本体不动）。重建镜像则用 `pixi run build && pixi run up`。

在 `.env` 里调（改完需 `docker compose up -d` 重建容器才生效）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMFYUI_IDLE_FREE_ENABLE` | `true` | 关掉空闲自动释放设 `false` |
| `COMFYUI_IDLE_FREE_SECONDS` | `60` | 空闲多久后释放（最小 5）。想优先「连续任务复用模型的加载速度」可调大，如 600 |
| `COMFYUI_IDLE_FREE_POLL` | `3` | 轮询间隔秒数（一般不用改） |
| `COMFYUI_IDLE_FREE_DROP_FILE_CACHE` | `true` | 是否丢弃模型文件页缓存（下一次加载会重新读盘） |
| `COMFYUI_IDLE_FREE_FILE_CACHE_MIN_MB` | `512` | 页缓存高于该值才丢弃 |
| `COMFYUI_IDLE_FREE_RESTART_SECONDS` | `0` | 空闲释放后再空闲 N 秒重启 ComfyUI（回收 anon/pinned，0=关闭） |
| `COMFYUI_IDLE_FREE_RESTART_MIN_ANON_MB` | `4096` | 重启阈值：anon+pinned 高于该值才重启 |

### 确认是哪一层占着（求助时带上这几条）

```bash
pixi run mem-status                                        # 一条命令拿到所有关键数据
docker stats comfyui-h3 --no-stream                        # 容器 MEM USAGE 是否贴着上限且不回落
docker inspect comfyui-h3 --format '{{.HostConfig.Memory}}' # 确认内存上限真的生效（24G = 25769803776）
docker exec -u root comfyui-h3 sh -c 'cat /sys/fs/cgroup/memory.current;
  grep -E "^(anon|file|active_file|inactive_file|pinned|slab)" /sys/fs/cgroup/memory.stat'
nvidia-smi --query-gpu=memory.used --format=csv
```

怎么读这些数：

- `file` / `active_file` 大：模型页缓存，**可回收**，但不会自己消失 —— 这正是守护第 3 步要丢的东西。
  `pixi run free` 后 `file` 应明显下降（日志里会打印 `file 页缓存 X → Y`）。
- `inactive_file` 大：已被内核标记为不活跃的页缓存，ComfyUI 自己也把它从可用内存里排除，属正常。
- `anon` / `pinned` 大且 `/free` 后不降：真正的常驻占用（锁页内存内核不能回收），需要
  `--disable-pinned-memory` / `--fast-disk` 或开启 `COMFYUI_IDLE_FREE_RESTART_SECONDS`。
- 释放日志里出现「跳过页缓存回收：找不到 /opt/ai-dock/bin/comfyui-drop-cache.py」= 容器还是旧镜像，
  跑 `pixi run mem-install` 或重建镜像。

### 空闲释放后仍然卡

说明单条工作流本身就超过了上限，与「跑完不释放」无关：

- **降常驻**：给 `COMFYUI_ARGS` 加 `--disable-pinned-memory`（不锁页，让内核可回收）或 `--fast-disk`（改为磁盘后备的 offload，适合 NVMe）；节点结果想再收紧可加 `--cache-ram 2 4`，极端情况 `--cache-none`。
- **跨模型族的批量任务之间** `pixi run restart`，用重启换确定性（代价是下次要重新加载）。
- **抬上限或拆容器**：把 `docker-compose.yml` 的 `memory` 提到 32G 起 / 64G 稳，或把不同模型族拆到不同时间窗跑。
- 注：`COMFYUI_ARGS` 里的 `--lowvram` 在当前 ComfyUI master 上**已是空操作**（dynamic VRAM 默认开启时该参数被忽略），真正管这块的是上面几个参数。

## Qwen 修图：工作流报缺节点 / 输出不按指令改

**现象 A**：打开 `qwen_image_edit_gguf*.json` 时节点框红、提示缺失节点（`UnetLoaderGGUF` / `CLIPLoaderGGUF`）。

**根因**：镜像是旧版，没装 ComfyUI-GGUF 节点。

**修复**：重建镜像（`pixi run build && pixi run up`；Dockerfile 里已有 clone + `pip install -r requirements.txt`）。确认方式：

```bash
docker exec comfyui-h3 ls /opt/ComfyUI/custom_nodes/ComfyUI-GGUF
docker exec comfyui-h3 /opt/environments/python/comfyui/bin/python -c "import gguf; print(gguf.__version__)"
```

**现象 B**：工作流能跑完，但输出几乎等于原图（指令没生效）。

**根因**：GGUF 文本编码器的视觉塔（mmproj）没被找到。ComfyUI-GGUF 按「文件名包含编码器基名（去掉量化后缀）」匹配 mmproj，匹配不上就把参考图当没有。日志（`pixi run logs`）里会有：

```
Can't find mmproj file for 'Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf' (matching:'qwen2.5-vl-7b-instruct')! Qwen-Image-Edit will be broken!
```

**修复**：确认 `models/text_encoders/` 下有 `Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf`（文件名必须含 `Qwen2.5-VL-7B-Instruct`）。缺了就跑 `pixi run models qwen-edit` 补下；自己从上游下载的话记得把 `mmproj-F16.gguf` 重命名成这个名字。

**现象 C**：Queue 后长时间卡在加载，或报 OOM / 容器被杀。

**修复**：降量化档（`QWEN_EDIT_QUANT=Q3_K_S pixi run models qwen-edit`，默认就是它）、调高 `docker-compose.yml` 里的 `memory` 上限、确认 `COMFYUI_ARGS` 带 `--lowvram`（默认带）。首次加载 9.2GB 主模型 + 4.7GB 文本编码器本身就慢，先等一次完整加载。

## 模型下载中断 / 想确认下载进度

下载脚本没有后台任务，直接在跑它的终端看输出即可；中断后重跑同一条命令会从断点续传，已下载完整的文件会打印 `SKIP (complete)`：

```bash
pixi run models extra            # 或 base / image / qwen-edit（不带参数即 all）
```

想确认某个文件是否完整，比对本地大小与远端大小（魔搭的 HEAD 不返回长度，用 Range 请求拿总大小；脚本里的 `remote_size()` 就是这么做的）：

```bash
ls -l models/diffusion_models/
curl -fsL --http1.1 -r 0-0 -o /dev/null -D - \
  "https://modelscope.cn/models/Comfy-Org/MiniMax-H3/resolve/master/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
  | grep -i content-range      # 形如：content-range: bytes 0-0/20967134080
```
