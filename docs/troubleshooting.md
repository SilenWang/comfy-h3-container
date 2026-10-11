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
