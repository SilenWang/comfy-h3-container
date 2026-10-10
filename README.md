# ComfyUI + MiniMax H3 容器化部署（comfy-h3-container）

在消费级 NVIDIA 显卡（12GB 显存实测可用）上，用 Docker 一键部署 **ComfyUI + MiniMax H3** 本地视频生成（画面 + 原生音频同步生成）。

本项目封装了完整可复现的部署链路：容器镜像定制（含所有踩坑修复）、模型下载脚本、`--lowvram` 低显存优化、Turbo 4 步加速、SageAttention 注意力加速与文本编码器显式卸载，实测 **512×288 / 4.46s 视频约 136 秒出片**（RTX 3060 12GB）。

## 特性

- Docker 容器化，一条命令启动（`docker compose up -d`）
- 原生支持 MiniMax H3（T2V / I2V / R2V，视频 + 32kHz 立体声音频同步生成）
- **参考生视频（R2V）**：最多 9 张参考图 / 3 段参考视频 / 3 段参考音频，锁定人物长相、风格、动作、运镜、音色（多视角人物图防“长相抖动”就靠它）
- **动作控制（Fun ControlNet Union）**：用姿态 / 深度 / 边缘 / HED / MLSD 控制视频驱动画面（内置 SDPose 从舞蹈视频提骨架），也支持 mask 局部重绘
- **多帧参考（Multiframe Reference）**：在时间轴任意帧锚定参考图或音频
- **输出高清化（SeedVR2 3B）**：自带的 H3 模板内置**可旁路**的放大/复原段，低清出片默认放大 2×（如 864×480 → 1728×960，720p/1080p 档；ComfyUI 内置节点，模型约 4GB，`pixi run models-upscaler-bg`）
- 12GB 显存实测可跑（int8 量化 + `--lowvram` + CPU offload）
- Turbo 4 步 LoRA 加速（实测提速 ~4.4×）
- **SageAttention 注意力加速**：两个 workflow 已内置 `PathchSageAttentionKJ` 节点（Ampere/Ada 约 1.3–2×，不改生成结果）
- **文本编码器显式卸载**：内置 `H3EvictTextEncoder`，编码后立即释放 15.7GB 的 Qwen3-VL，避免采样阶段反复经 PCIe 换入换出
- WebUI + REST API（ComfyUI 原生）
- 内置 [Comfy MCP Local](https://github.com/Comfy-Org/comfy-mcp)：在 Claude Code / Cursor 里用自然语言驱动本地 ComfyUI（容器内 stdio server）
- 集成 [artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp)：让 Agent **直接搭建 / 编辑 / 校验工作流**；作为容器内服务由 supervisord 托管（Streamable HTTP，宿主 9100），日志与 ComfyUI / caddy 一起进 `docker logs`
- WebUI 认证可一键关闭（局域网自用、免每次输密码）
- 模型一键下载脚本（断点续传）

## 硬件要求

| 项目 | 最低 | 推荐 |
|---|---|---|
| GPU | NVIDIA 12GB 显存（RTX 3060 实测） | 24GB+ 显存（更快、可跑更高分辨率） |
| 系统内存 | 32GB | 64GB（offload 稳定） |
| 磁盘 | 45GB 可用 | NVMe SSD |
| 软件 | Docker + nvidia-container-toolkit | Linux / WSL2 |

> 非 NVIDIA（AMD ROCm / Apple Silicon）请参考文末的社区方案。

## 快速开始

```bash
# 1. 克隆本项目
git clone https://github.com/SilenWang/comfy-h3-container.git
cd comfy-h3-container

# 2. 配置认证（局域网自用建议直接关闭密码）
cp .env.example .env
# .env.example 默认已设 WEB_ENABLE_AUTH=false（免密码访问）；
# 想保留认证则改回 true，并设置 WEB_PASSWORD

# 3. 下载模型（约 43GB，支持断点续传）
./scripts/download_models.sh
# 首次下载很慢（hf CDN 实测约 3–10MB/s，可能几小时），推荐改用后台方式：
#   pixi run models-bg && pixi run models-status
# 想输出 720p / 1080p 高清成片，再下约 4GB 的放大模型（见「输出高清化」）：
#   pixi run models-upscaler-bg

# 4. 构建并启动
docker compose up -d --build
```

> ⚠️ 挂载目录要提前以**你自己的用户**建好：`mkdir -p models output`。若目录不存在，`docker compose` 会以 root 创建，容器内以 uid 1000 运行的 ComfyUI 会写不进去，表现为 SaveVideo 报 `PermissionError: '/opt/ComfyUI/output/video'`，或模型列表为空。

启动完成后访问 http://localhost:8188。默认 `.env.example` 已关闭认证，**直接进入、无需输密码**；若 `WEB_ENABLE_AUTH=true`，则账号固定为 `user`、密码为 `.env` 中的 `WEB_PASSWORD`。

> 可选：仓库带 `pixi.toml`，常用命令可走统一入口——`pixi run up` / `down` / `logs` / `models` / `models-bg` / `mcp-config`。只用原生 `docker compose` 也完全可以。

### 模型下载（可能几小时，支持断点续传）

**默认从 ModelScope（魔搭）下载**，国内速度快；也可切回 HuggingFace。脚本强制 HTTP/1.1、自动重试、断点续传。后台方式：

```bash
pixi run models-bg       # 后台启动下载（默认魔搭），立即返回
pixi run models-status   # 查看各文件已下载大小与日志尾部
pixi run models-logs     # 实时跟踪 .build/models.log
```

切换下载源：加环境变量 `MODELS_SOURCE=modelscope|hf`（默认 `modelscope`），或直接用 `-hf` 任务，例如 `pixi run models-hf-bg`。两个模型仓库（`Comfy-Org/MiniMax-H3`、`Comfy-Org/SDPose`、`larryvrh/MiniMax-H3-Turbo-Lora`）在魔搭上都有对应文件。

脚本会按远端大小校验完整性：中断后重跑 `pixi run models-bg` 会从断点接着下，**已下载但未完成的文件不会被误跳**。

> 想用**参考生视频（R2V）**或**动作控制（Fun ControlNet）**，再下约 25GB 的额外模型（`ref2va` 主模型、控制补丁、参考 Turbo LoRA、SDPose 姿态提取）：
> ```bash
> pixi run models-extra-bg        # 后台启动（默认魔搭，可断点续传）
> pixi run models-extra-status    # 查看进度
> ```
> 切 HuggingFace 用 `pixi run models-extra-hf-bg` 或 `MODELS_SOURCE=hf pixi run models-extra-bg`。只在做 T2V/I2V 时不必下载这部分，见下文「更多参考方式」。

> 想要**高清成片**（720p / 1080p），再下约 4GB 的 SeedVR2 放大模型：
> ```bash
> pixi run models-upscaler-bg       # 后台启动（默认魔搭，可断点续传）
> pixi run models-upscaler-status   # 查看进度
> ```
> 切 HuggingFace 用 `pixi run models-upscaler-hf-bg`。这一套是工作流里「HD Upscale (SeedVR2 3B)」那一段用的，见下文「输出高清化」。

### 用外部模型目录（避免每次重新下载）

模型本来就存在挂载卷里，容器重建不会丢。默认落在仓库内的 `./models`；如果想多个项目 / 多台机器共用同一份模型（比如放在 NAS 或大盘上），把 `MODELS_DIR` 指向外部目录即可：

```bash
# .env
MODELS_DIR=/data/ai-models/comfy-h3
OUTPUT_DIR=/data/ai-output/comfy-h3      # 可选，同理
```

`docker-compose.yml` 用的是 `${MODELS_DIR:-./models}`，所以不设就是原来的 `./models`，设了就挂外部目录到容器内的 `/workspace/models`。下载脚本也认同一个变量，直接把模型下到外部盘：

```bash
MODELS_DIR=/data/ai-models/comfy-h3 pixi run models-bg
```

两个注意点（就是之前踩过的坑）：

1. **目录要提前以你自己的用户建好**（`mkdir -p /data/ai-models/comfy-h3`）。目录不存在时 Docker 会以 root 创建 bind 源，容器内以 uid 1000 运行的 ComfyUI 会读不到 / 写不进。
2. 只读共享盘可以把它挂成只读，在 compose 里写 `"${MODELS_DIR}:/workspace/models:ro"`；下载仍在宿主侧写这个目录，不受影响。


### 镜像构建耗时较长时怎么办（推荐用可续建的后台方式）

首次构建要拉 torch cu126 + ComfyUI 依赖，可能超过一次性前台命令能跑完的时间。Docker 会把已完成的分层写进 BuildKit 缓存，所以拆成「后台启动 + 反复重跑」可以断点续建：

```bash
pixi run build          # 后台启动构建，立即返回；已在跑则直接提示
pixi run build-status   # 查看是否还在跑 + 日志尾部
pixi run build-logs     # 实时跟踪 .build/build.log
pixi run up             # 构建完成后启动容器（镜像已就绪，不再重建）
```

即使进程被环境回收，缓存仍在，重跑 `pixi run build` 会自动从上次完成的分层继续，不会从头再来。只想快速增量构建时也可以直接 `pixi run up-build`。


### 生成视频

1. WebUI 左侧 **Workflows** 选仓库自带模板：`minimax_h3_t2v_bund`（文生视频）/ `minimax_h3_i2v`（图生视频）/ `minimax_h3_r2v`（参考生视频）/ `minimax_h3_fun_controlnet_union`（动作控制）/ `minimax_h3_multiframe_reference`（多帧参考）；也可从 **Template Library → Video** 选官方 H3 模板
2. 点 Queue 执行，等待输出（右侧 Video 面板可预览/下载）
3. 输出文件同时保存在宿主的 `./output/` 目录

### 输出高清化（HD Upscale，SeedVR2 3B）

H3 本体以较低分辨率出片（分辨率越低速度越快、显存越省），所以自带模板另接了一段**可旁路**的 SeedVR2 放大 / 细节复原件，把成片再放大一档。它对应官方蓝图 `Upscale Video (SeedVR2 3B Int8)`，用的全是 ComfyUI 内置节点（`comfy_extras/nodes_seedvr.py`），不需要额外自定义节点。

前置：先下约 4GB 的放大模型（落到 `models/diffusion_models/seedvr2_3b_int8_convrot.safetensors` 与 `models/vae/seedvr2_ema_vae_fp16.safetensors`）：

```bash
pixi run models-upscaler-bg       # 后台下载（默认魔搭，可断点续传）
pixi run models-upscaler-status   # 查看进度
```

**该段默认开启**，所以下完模型、重开一次工作流就能出高清成片：

| 模板 | `ResolutionSelector` | 关掉放大时的出片 | 开启放大（2×，默认） |
|---|---|---|---|
| `minimax_h3_t2v_bund` / `minimax_h3_i2v` | 0.2 MP 16:9 | 608×352 | **1216×704** |
| `minimax_h3_r2v` / `minimax_h3_fun_controlnet_union` / `minimax_h3_multiframe_reference` | 0.4 MP 16:9 | 864×480 | **1728×960** |

三个开关（都在那段放大节点的左侧，节点标题已写明用途）：

- **`Boolean (Enable HD Upscale)`**（默认 `true`）—— `true` 走放大段；`false` 直接旁路到原始解码图（快、省显存，分辨率回到上表第三列）。
- **`Scale (HD multiplier)`**（`ResizeImageMaskNode`，默认 `2.0` + lanczos）—— 放大倍率。想要更高分辨率就调大（`2.5` / `3.0`，显存和耗时同步上升）；调回 `1.0` 相当于只让 SeedVR2 做修复不放大。想更精确地拿到 1080p，也可以改 `ResolutionSelector` 的 megapixels。
- **`Boolean (Split Latent)`**（默认 `true`）—— SeedVR2 的 latent 按显存分块采样再合并（`Split SeedVR2 Latent` 取 `auto`，按当前空闲显存预测块大小），12GB 显存建议保持开启；显存充足可关掉以省去分块开销。

参数沿用官方蓝图默认：`KSampler (SeedVR2, 1 step)`（steps 1 / cfg 1.0 / euler / simple / denoise 1.0，所以这一段额外耗时有限）、`color_correction_method = none`、`temporal_overlap = 8`（相邻分块交叉淡入淡出，抑制接缝闪烁）。

> **官方模板库里没有这段**：Template Library → Video 里的 H3 模板是纯净版，要高清成片请用仓库自带的这 5 个模板（容器启动即在 WebUI 的 Workflows 列表里）。反过来，已有视频想要高清化，也可以直接用官方 `Upscale Video (SeedVR2 3B Int8)` 蓝图单独跑一遍。

### 加速配置（两个自带 workflow 已调好）

仓库里的 `workflows/minimax_h3_t2v_bund.json` 与 `workflows/minimax_h3_i2v.json` 就是实测的 12GB 配置，容器启动即出现在 WebUI 的 Workflows 列表，已包含：

- `MiniMaxH3TurboLoRA`（`minimax_h3_turbo_v4_step600_ema.safetensors`，4 步）+ `MiniMaxH3TurboSampler`
- `PathchSageAttentionKJ`（ComfyUI-KJNodes）—— 注意力加速，模式默认 `sageattn_qk_int8_pv_fp16_cuda`、`allow_compile` 关闭。这是唯一"不改结果"的提速手段（Ampere/Ada 约 1.3–2×）；镜像构建期会从源码编译官方 SageAttention v2.2.0，若构建失败把模式切到 `auto`（V1 Triton）或 `disabled` 即可无损回退。既有容器若报 `No module named 'sageattention'`，直接 `pixi run fix-sage-attn` 现场补装即可，无需重建镜像（见「故障排查」）
- `H3EvictTextEncoder`（ComfyUI-MAINodes）—— conditioning 直通节点，编码完成后立即卸载 Qwen3-VL 文本编码器，必须位于 `BasicGuider` 之前
- `BasicScheduler` 步数 **4** + 容器参数 `--lowvram`

从官方模板手工改造时按同一拓扑接线：

```
UNETLoader → MiniMaxH3TurboLoRA → PathchSageAttentionKJ → ┬→ BasicGuider
                                                          └→ BasicScheduler
MiniMaxH3ImageToVideo.conditioning → H3EvictTextEncoder → BasicGuider.conditioning
CLIPLoader ──→ MiniMaxH3ImageToVideo.clip
           └→ H3EvictTextEncoder.clip
```

> **EasyCache 仅在需要时单独叠加**：它在较长片段 / 较多步数时收益明显（约 1.8×），但 4 步配置下收益有限、且后段可能起颗粒，因此**未**放进自带 workflow。要用就自行添加默认参数的 `EasyCache` 节点，且不要与其它缓存节点（如 Spectrum）叠在同一模型分支上。

## 更多参考方式：R2V / 动作控制 / 多帧参考

除 T2V / I2V 外，H3 原生支持三种更强的「参考」玩法。仓库已附对应官方工作流，使用前先下额外模型（约 25GB，见上文 `pixi run models-extra-bg`）。这几个模板需要 **ComfyUI ≥ 0.35.0**——本镜像构建时会拉最新 master，满足要求。

### 1. 多视角人物一致性：参考生视频（R2V）

`minimax_h3_r2v.json`，核心是 `MiniMax H3 Reference to Video` 节点。给同一个人的正面 / 侧面 / 背面等多张图，模型据此锁定长相，显著降低视频里脸部和服装的抖动漂移。

- 参考可以是图片、视频、音频的任意组合，上限 **9 张图 + 3 段视频 + 3 段音频**。
- 在 prompt 里按连接顺序用 `<Picture 1>`、`<Video 1>`、`<Audio 1>` 引用，并**显式分工**（哪张管长相、哪张管风格、哪段管动作 / 运镜 / 音色）——官方实测这样效果好很多。
- `ref_image_size`：`match`（缩到出图分辨率，快）；`max`（短边最高 2048，长相更准但更慢）。
- R2V 用的是 **ref2va** 主模型，与 T2V / I2V 的 `fl2va` 是两套权重（额外模型里已含）。
- 4 步 Turbo LoRA 会削弱参考约束：人物越要像，越应跑 **20 步（必要时 25 步）**。

### 2. 舞蹈 / 动作控制：Fun ControlNet Union

`minimax_h3_fun_controlnet_union.json`，核心是 `Apply MiniMax H3 Fun ControlNet` 节点，把一段**控制视频**作为运动模板。单个检查点同时支持 **Canny / Depth / HED / MLSD / Pose**，还能接 `mask` 做局部重绘。

- 工作流自带 **SDPose 子图**：直接喂一段舞蹈视频，它自动提取骨骼，输出复现舞者动作（示例输入即 `dancer_field_pose.mp4`）。也可自行预处理后直接接 `control_video`。
- `guidance_scale` 保持 1.0；只有画面明显偏离控制时才把补丁 `strength` 调大。
- 依赖 `model_patches/` 下的控制补丁与 `checkpoints/` 下的 SDPose，需 ComfyUI ≥ 0.35.0。
- 想「免姿态提取、直接迁移动作且保住人物身份」，可另试 Wan Animate 2（另一条管线，要另下模型，本仓库未内置）。

### 3. 时间轴锚点：多帧参考（Multiframe Reference）

`minimax_h3_multiframe_reference.json`，用 `MiniMaxH3AddGuide` 在**任意帧**锚定参考图 / 音频（不再局限于首尾帧）。例如在第 60 帧钉一张定妆图，强制视频经过该帧；或喂前 22 帧 + 音频让模型续写。

- 把 H3 节点的 `positive` 与 latent 接到 `MiniMaxH3AddGuide`，给 `image` / `audio` + `frame_idx`（负数从尾部数）；可串联多个节点锚多个帧。
- 它是**条件锚点**而非视频转视频：要改风格用 R2V，要重绘局部用 Fun ControlNet 的 mask。

> 这三个模板基于 Comfy-Org 官方模板，仅把视频 VAE 指向本仓库已下载的 `minimax_h3_video_vae_fp16.safetensors`，省去重复下载 int8 VAE。

## AI 辅助：用 MCP 驱动 ComfyUI（本地 / 远程）

仓库接了两套 MCP，分工不同、可并存：

- **[官方 comfy-mcp](https://github.com/Comfy-Org/comfy-mcp)**（容器内 stdio）：基于 `comfy-cli`，强于**跑工作流 + 填模板槽位 + 查询容器里真实安装的节点/模型**，工具语义官方稳定。
- **[artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp)**（容器内托管服务）：第三方，强于**让 Agent 直接搭建 / 编辑 / 校验工作流**；由 supervisord 随容器启动并暴露 Streamable HTTP。想让 Agent 帮你**预配置工作流**就用它。

### 1. 官方 Comfy MCP Local — 容器内 stdio（跑现成工作流，推荐）

[官方 comfy-mcp](https://github.com/Comfy-Org/comfy-mcp) 是 stdio MCP server，引擎是 `comfy-cli`。本镜像把它**装在容器内**，并已把 comfy-cli 的 workspace 指向 `/opt/ComfyUI`，所以开箱即用。

**为什么装在容器内**：MCP 直连容器内 ComfyUI 的 `127.0.0.1:18188`，**完全绕过 8188 上的 caddy 反代**，因此与 WebUI 认证开关无关——这也是「MCP 不用再单独验证」的原因。

客户端配置（先确认容器在跑：`pixi run up`）：

```jsonc
// Claude Desktop / Cursor 配置片段；用 `pixi run mcp-config` 可随时打印
{
  "mcpServers": {
    "comfy-mcp": {
      "command": "docker",
      "args": ["exec", "-i", "comfyui-h3", "comfy-mcp"]
    }
  }
}
```

```bash
# Claude Code：一条命令注册
claude mcp add comfy-mcp -- docker exec -i comfyui-h3 comfy-mcp
```

配好后就能说「确认本地 ComfyUI 在跑，然后跑某个工作流并把视频给我」——agent 会依次调 `server_info` → `run_workflow` → `fetch_outputs`。它能**看到容器内真实安装的节点和模型**（含 H3 与 Turbo 插件），比通用知识库可靠。

> 排查：镜像构建时已自动执行 `comfy set-default /opt/ComfyUI`。若容器内工具报找不到 workspace，重新执行一次即可：
> `docker exec comfyui-h3 comfy set-default /opt/ComfyUI`。

<details>
<summary>备选：把官方 MCP server 跑在宿主机上（需要额外准备）</summary>

仓库自带 `pixi` 环境，也可以在宿主直接跑：

```bash
pixi install                  # 装 comfy-cli + comfy-mcp
pixi run mcp-config host      # 打印带绝对路径的客户端配置
```

两条注意：① comfy-cli 需要有可用 workspace（宿主没有 ComfyUI 目录时先 `comfy install` 或 `comfy set-default <一个 ComfyUI 检出目录>`）；② 宿主侧的 `COMFYUI_URL` 会指向 `http://127.0.0.1:8188`，也就是 **caddy 那一层**——若 `WEB_ENABLE_AUTH=true` 会直接返回 401，需要先关闭认证。综合考虑，容器模式更省事。

</details>

### 2. artokun/comfyui-mcp — 容器内托管服务（Agent 搭 / 改工作流 + 统一日志）

官方 comfy-mcp 偏「执行 + 模板 + 自省」，**不能从零搭图**。若你想让 Agent **帮你预配置 / 编辑工作流**，用第三方的 [artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp)（npm 包 `comfyui-mcp`）：它能 `create_workflow`（从模板或从零建节点 / 连线 / 设参）、`modify`（增删改连）、`validate`（运行前校验）、`get_workflow` / `save_workflow`（读 / 存工作流库），还带模型家族 skills（含 **MiniMax H3**）。

**它以容器内服务运行，由 supervisord 托管、随容器一起启动**（不需要宿主另起进程）：

- 容器内以 **Streamable HTTP** 监听 `0.0.0.0:19100`，`docker-compose.yml` 映射到宿主 `0.0.0.0:9100`（不写 IP 即绑所有接口，**同机其他容器与局域网都能访问**）。
- 直连同容器 ComfyUI 的 `127.0.0.1:18188`，绕过 8188 上的 caddy。
- 日志写 `/var/log/supervisor/comfyui-mcp.log`；ai-dock 的 `logtail` 会把该目录所有日志汇总到容器 stdout，因此 **comfyui / caddy / comfyui-mcp 的日志在 `docker compose logs` 里都能同时看到**。

客户端配置（`pixi run mcp-config artokun` 可随时打印）：

```jsonc
{
  "mcpServers": {
    "comfyui": {
      "type": "http",
      "url": "http://<宿主机IP>:9100/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

```bash
claude mcp add --transport http comfyui http://<宿主机IP>:9100/mcp \
  --header "Authorization: Bearer <token>"
```

#### 谁能连、用什么地址

端口映射绑在**宿主**上，而容器各有独立网络命名空间 —— **容器内的 `127.0.0.1:9100` 是它自己的 loopback，连不到宿主的 9100**（同机其他容器也一样）。按调用方所在位置选地址：

| 调用方 | 端点 | 说明 |
|---|---|---|
| 宿主机本机 | `http://127.0.0.1:9100/mcp` | Claude Code / Cursor 跑在宿主上时 |
| **同机其他容器** | `http://<宿主在该容器网络上的网关IP>:9100/mcp` | 默认 bridge 是 `172.17.0.1`；自定义网络用 `docker network inspect <网络名>` 看 `Gateway`。更省事：给该容器加 `--add-host host.docker.internal:host-gateway`，然后用 `host.docker.internal` |
| 局域网其他机器 | `http://<宿主机IP>:9100/mcp` | 需防火墙放行 9100 |
| 与 `comfyui-h3` 同一 docker 网络的容器 | `http://comfyui-h3:19100/mcp` | 走容器网络直连**容器内**端口，不经宿主端口映射，最直接（compose 默认网络名 `<项目名>_default`，`docker network ls` 可查） |

同机其他容器接入示例（`host-gateway` 需要 Docker ≥ 20.10）：

```bash
docker run --rm --add-host host.docker.internal:host-gateway <你的镜像> \
  curl -X POST http://host.docker.internal:9100/mcp \
    -H 'Authorization: Bearer <token>' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

客户端配置里把 `url` 换成上表对应那一行即可：

```jsonc
{
  "mcpServers": {
    "comfyui": {
      "type": "http",
      "url": "http://host.docker.internal:9100/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

可配置项：

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMFYUI_MCP_HTTP_TOKEN` | `comfy-h3-mcp` | 入站鉴权令牌（`Authorization: Bearer` / `X-API-Key`）。**端口默认对外开放，务必改成强随机值** |
| host 端口映射 | `9100:19100` | 绑宿主所有接口（同机其他容器 + 局域网可达）。想收回成只允许宿主机本机：改 `docker-compose.yml` 为 `"127.0.0.1:9100:19100"` |
| `COMFYUI_MCP_PORT_LOCAL` | `19100` | 容器内监听端口（镜像 ENV） |

> ⚠️ **第三方 + 有限维护**：`artokun/comfyui-mcp` 是社区实现（MIT / Node ≥22），README 标注 limited maintenance，工具面与官方 comfy-cli **不通用**；H3 的 `MiniMaxH3TurboLoRA` / `PathchSageAttentionKJ` / `H3EvictTextEncoder` 这套专用链它也不认识，但能读容器里**实际安装**的 `/object_info`。最稳的用法是把仓库现成的 `workflows/*.json` 当模板喂给 Agent，让它在此基础上改参 / 接线。
>
> **安全**：端口默认绑宿主所有接口（`9100:19100`），同机容器与局域网都能连，而鉴权只有 Bearer token —— 默认值 `comfy-h3-mcp` 形同公开。**务必先在 `.env` 里设强随机值**（`openssl rand -hex 16`），且只部署在可信网络；跨不可信网络请套 TLS 反代或走 Tailscale / WireGuard。只想宿主机本机用：把映射改回 `"127.0.0.1:9100:19100"`。

<details>
<summary>查看 / 管理容器内服务（supervisor）</summary>

```bash
pixi run logs                                        # 跟踪容器日志（comfyui + caddy + comfyui-mcp 汇总）
docker exec -it comfyui-h3 supervisorctl status
docker exec -it comfyui-h3 supervisorctl restart comfyui-mcp
docker exec -it comfyui-h3 tail -f /var/log/supervisor/comfyui-mcp.log
```

只想看某个服务：`docker exec comfyui-h3 tail -f /var/log/supervisor/caddy.log`。

</details>

<details>
<summary>与官方 comfy-mcp 的分工（两套可并存）</summary>

- **官方 comfy-mcp**（容器内 stdio，server 名 `comfy-mcp`）：官方维护、跟 `comfy-cli` 走、工具语义稳定；强于「跑工作流 + 填模板槽位 + 自省真实节点 / 模型」。日常出片、跑现成工作流用它。
- **artokun comfyui-mcp**（容器内托管服务，server 名 `comfyui`）：强于「让 Agent 搭 / 改 / 校验工作流」+ 远程 HTTP + 模型家族 skills。需要 Agent 帮你**配置工作流**时用它。

</details>

## WebUI 认证：是什么、能不能去掉

**不是 ComfyUI 自带的，ComfyUI 本体没有任何账号体系。** 认证来自基础镜像 [ai-dock/comfyui](https://github.com/ai-dock/comfyui) 内置的 **caddy 反向代理**（HTTP Basic Auth），它的设计目的是防止公网端口扫描器发现并滥用服务。所以：

- **能去掉**，官方支持一个环境变量开关：`WEB_ENABLE_AUTH=false`。
- 去掉后对本项目没有副作用：WebUI、REST API、容器内 MCP 全都正常工作。

请求链路上认证在哪一层：

```
宿主 :8188  ──►  容器内 caddy :8188  ──(可选的 Basic Auth)──►  容器内 ComfyUI :18188
                        ▲                                              ▲
                  浏览器访问走这里                        容器内 MCP / 脚本直连走这里
```

改法（已在 `.env.example` 里默认设好）：

```bash
# .env
WEB_ENABLE_AUTH=false
```

```bash
docker compose up -d      # 重建容器生效
```

想改回来：设回 `true`（或删掉该行）并设置 `WEB_PASSWORD`，再 `docker compose up -d`。

> ⚠️ **安全提醒**：关闭认证后，**任何能访问 8188 端口的人都能无密码使用 WebUI 和 API**。局域网内自用没问题，但如果这台机器有公网 IP / 端口转发，请不要关闭，或用防火墙限制来源网段。只想本机用（连局域网也不开放）可以把 `docker-compose.yml` 的端口改成 `"127.0.0.1:8188:8188"`。

## 配置说明

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `WEB_ENABLE_AUTH` | `true`（镜像默认）/ `false`（`.env.example`） | caddy Basic Auth 开关。`false` 免密码访问，局域网自用推荐；详见上文认证章节 |
| `WEB_PASSWORD` | `comfy-h3`（镜像默认） | 仅在 `WEB_ENABLE_AUTH=true` 时生效（账号固定 `user`） |
| `COMFYUI_PORT_HOST` | `8188` | 对外端口（caddy 反向代理） |
| `COMFYUI_PORT_LOCAL` | `18188` | 容器内 ComfyUI 监听端口（**不可与 HOST 相同**，否则端口冲突） |
| `COMFYUI_ARGS` | `--listen 0.0.0.0 --lowvram` | ComfyUI 启动参数（`--lowvram` 为 12GB 显存关键优化） |
| `COMFY_LOCAL_URL` | `http://127.0.0.1:18188` | 容器内 comfy-cli / artokun 连 ComfyUI 的地址（供 MCP 使用） |
| `COMFYUI_MCP_HTTP_TOKEN` | `comfy-h3-mcp`（镜像默认） | artokun MCP 服务的入站鉴权令牌（`Authorization: Bearer` / `X-API-Key`）；对局域网 / 公网开放前务必改强 |

模型目录结构（`models/` 挂载进容器 `/workspace/models`）：

```
models/
├── diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors   20.97 GB
├── text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors          15.69 GB
├── vae/minimax_h3_video_vae_fp16.safetensors                            5.21 GB
├── vae/minimax_h3_audio_vae_fp32.safetensors                            0.61 GB
├── loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors      1.96 GB（可选）
├── loras/minimax_h3_turbo_v4_step600_ema.safetensors                    0.78 GB（推荐）
├── diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors  19.53 GB（R2V，额外）
├── loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors     1.82 GB（R2V Turbo，额外）
├── model_patches/minimax_h3_fun_controlnet_union_pruned_int8_convrot…  2.14 GB（动作控制，额外）
├── checkpoints/sdpose_wholebody_fp16.safetensors                        1.79 GB（姿态提取，额外）
└── diffusion_models/rt_detr_v4-x-hgnet_fp16.safetensors                 0.12 GB（SDPose 检测器，额外）
```

> 后 5 项（约 25GB）仅 R2V / 动作控制 / 多帧参考需要，用 `pixi run models-extra-bg` 下载；只做 T2V / I2V 不必装。

## 📊 实测性能（RTX 3060 12GB）

| 配置 | 参数 | 耗时 | 说明 |
|---|---|---|---|
| 官方 8 步（未优化） | 512×288 / 4.46s | ~600s | 首次含 37GB 模型加载 |
| Turbo 4 步 + EasyCache + `--lowvram` | 512×288 / 4.46s | ~136s | 历史实测基线（此配置含 EasyCache，非当前自带 workflow） |
| **Turbo 4 步 + SageAttention + 文本编码器卸载 + `--lowvram`** | 608×352 / 2.33s | ~79s | 当前自带 workflow 默认配置，RTX 3060 12GB 实测（含模型加载）；SageAttention v2.2.0 由镜像构建期源码编译 |

更高分辨率（1344×768 原生画布 / 5s）参考社区实测约 7 分钟/段（Turbo 4 步）。

> 注意：`SageAttention` 只在 Ampere/Ada 及以后有收益（**RTX 30/40 系约 1.3–2×，Blackwell 较小**）；`H3EvictTextEncoder` 在 `--gpu-only` 模式下是 no-op。若 SageAttention 构建失败，把 `PathchSageAttentionKJ` 切到 `auto`（V1 Triton）或 `disabled` 即可无损回退；既有容器缺失时用 `pixi run fix-sage-attn` 现场补装。

## 已知限制

1. 12GB 显存为"能跑但慢"的降级配置：权重（~37GB）无法全部驻留显存，推理时 CPU offload，速度受 PCIe 带宽限制
2. v4-600 Turbo LoRA 在 **4 步 + 大幅快速运动**场景偶有 motion-smear，遇到可改用 6-8 步（仍快于官方 20 步）
3. 完整 H3 系统（H3-Context-IR / 2K 再生）为云端 API，未开源；本方案为本地 H3-Base（768p 档）
4. 模型权重遵循 MiniMax H3 社区许可（注意地区限制：排除美/欧/英/韩）
5. Comfy MCP Local 的 `launch_comfyui` / 停止 / 日志类工具语义受限：ComfyUI 在容器内由 ai-dock 启动，comfy-cli 再 `launch` 会另起一个进程。日常用 `run_workflow` / `server_info` / `fetch_outputs` 不受影响
6. PyPI 的 `sageattention` 只有 V1（Triton），不含 KJ 节点默认模式所需的 2.x CUDA 算子，故镜像构建期从源码编译官方 SageAttention **v2.2.0**（用 codeload tarball 拉源码，ai-dock 自带 nvcc，目标 arch 8.0/8.6，耗时数分钟），并先装 PyPI V1 兜底、编译后校验 import，避免"构建成功却漏装"。万一构建失败，把 `PathchSageAttentionKJ` 的模式改为 `auto`（V1）或 `disabled` 即可无损回退；既有容器可 `pixi run fix-sage-attn` 现场补装
7. 自带 workflow **不再内置 EasyCache**：4 步配置下其收益有限且后段可能起颗粒。需要时自行叠加默认参数的 `EasyCache`，且不要与其它缓存节点（如 Spectrum）叠在同一模型分支上
8. 内置工作流的视频解码用 `VAEDecodeTiled`（分块解码）：显存占用显著低于整段解码，且**画质逐像素一致**（同种子 A/B 实测 PSNR=inf / SSIM=1.0）。但 12GB 卡上限制时长的**真正瓶颈在采样阶段**：720p（1280×736）实测 **5 秒**可稳定出片，10 秒以上采样/解码均易 OOM；要更长请降到 0.4MP/0.2MP，或换 16GB+ 显存的卡
9. R2V / 动作控制 / 多帧参考需额外约 25GB 模型（`pixi run models-extra-bg`），且 R2V 用的是独立的 `ref2va` 权重（与 T2V/I2V 的 `fl2va` 不通用）；三者需要 ComfyUI ≥ 0.35.0（本镜像构建时拉最新 master，满足）
10. R2V 的 4 步 Turbo LoRA 会削弱参考约束：人物一致性要求高时请跑 20–25 步（不是 4 步）；`ref_image_size=max` 更准但更慢
11. Fun ControlNet 依赖 SDPose 姿态提取，长视频 / 多人场景会增加预处理时间，控制强度与步数需按片段调
12. artokun/comfyui-mcp 是第三方实现（limited maintenance），工具面与官方 comfy-cli **不通用**；它由容器内 supervisord 托管，宿主端口默认绑所有接口（`0.0.0.0:9100`，同机其他容器 / 局域网可达），务必先把 `COMFYUI_MCP_HTTP_TOKEN` 改强；只想宿主机本机用可把映射收回 `"127.0.0.1:9100:19100"`（详见上文「artokun/comfyui-mcp」）

## 故障排查

### `PathchSageAttentionKJ` 报 `ModuleNotFoundError: No module named 'sageattention'`

**现象**：执行 i2v/t2v 工作流时，节点 137（`PathchSageAttentionKJ`）抛出 `ModuleNotFoundError`，日志里前面有 `Using sage attention mode: sageattn_qk_int8_pv_fp16_cuda`。

**根因**：镜像构建期的 SageAttention 源码安装失败，但被 `|| echo WARN` 容错吞掉，于是镜像"构建成功"却漏装了 `sageattention`（旧版 Dockerfile 用 `git clone` 拉源码，部分构建机会卡在 index-pack / 超时失败）。确认方式：

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

> 现版本 Dockerfile 已改用 codeload tarball + 重试来拉源码，并先装 PyPI V1 兜底、编译后校验 import，不会再出现"构建成功却漏装"的静默失败。

## 参考项目与致谢

本项目为以下开源项目的整合与容器化封装，**衷心感谢**各项目作者：

| 项目 | 用途 |
|---|---|
| [ai-dock/comfyui](https://github.com/ai-dock/comfyui) | 容器基础镜像（ComfyUI Docker 方案） |
| [Comfy-Org/ComfyUI](https://github.com/Comfy-Org/ComfyUI) | ComfyUI 本体（≥0.30 原生支持 MiniMax H3） |
| [MiniMax-AI/MiniMax-H3](https://github.com/MiniMax-AI/MiniMax-H3) | MiniMax H3 官方模型与文档 |
| [Comfy-Org/MiniMax-H3](https://huggingface.co/Comfy-Org/MiniMax-H3) | 量化模型权重（int8 剪枝 + nvfp4-AWQ，适配消费级显卡） |
| [shiqikuangsan31/MiniMax-H3-12GB-ComfyUI-Guide](https://github.com/shiqikuangsan31/MiniMax-H3-12GB-ComfyUI-Guide) | 12GB 显存优化方案（`--lowvram`、Turbo 4 步 + EasyCache 实测数据） |
| [larryvrh/ComfyUI-MiniMax-H3-Turbo](https://github.com/larryvrh/ComfyUI-MiniMax-H3-Turbo) | Turbo LoRA 节点插件 |
| [larryvrh/MiniMax-H3-Turbo-Lora](https://huggingface.co/larryvrh/MiniMax-H3-Turbo-Lora) | v4-600 Turbo LoRA 权重 |
| [kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) | `PathchSageAttentionKJ` 注意力加速节点（+ `sageattention`） |
| [matlowai/ComfyUI-MAINodes](https://github.com/matlowai/ComfyUI-MAINodes) | `H3EvictTextEncoder` 编码后卸载文本编码器节点 |
| [Comfy-Org/comfy-mcp](https://github.com/Comfy-Org/comfy-mcp) | 官方 Comfy MCP Local（容器内安装） |
| [Comfy-Org/comfy-cli](https://github.com/Comfy-Org/comfy-cli) | comfy-mcp 的底层引擎 |
| [artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp) | 容器内托管 MCP：让 Agent 搭建 / 编辑工作流（Streamable HTTP） |
| [Saganaki22/ComfyUI-sol-attn](https://github.com/Saganaki22/ComfyUI-sol-attn) | （可选）Sol-Attn 无损加速，支持 SM86（RTX 30 系） |
| [ModelTC/Minimax-H3-Turbo](https://github.com/ModelTC/Minimax-H3-Turbo) | 4 步蒸馏 LoRA 参考 |

## License

- 本仓库部署脚本/配置：Apache-2.0
- ComfyUI / ai-dock / 各插件：遵循其各自开源许可证
- MiniMax H3 模型权重：MiniMax H3 Community License（注意地区限制）
