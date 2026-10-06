# ComfyUI + MiniMax H3 容器化部署（comfy-h3-container）

在消费级 NVIDIA 显卡（12GB 显存实测可用）上，用 Docker 一键部署 **ComfyUI + MiniMax H3** 本地视频生成（画面 + 原生音频同步生成）。

本项目封装了完整可复现的部署链路：容器镜像定制（含所有踩坑修复）、模型下载脚本、`--lowvram` 低显存优化、Turbo 4 步加速、SageAttention 注意力加速与文本编码器显式卸载，实测 **512×288 / 4.46s 视频约 136 秒出片**（RTX 3060 12GB）。

## 特性

- Docker 容器化，一条命令启动（`docker compose up -d`）
- 原生支持 MiniMax H3（T2V / I2V / R2V，视频 + 32kHz 立体声音频同步生成）
- 12GB 显存实测可跑（int8 量化 + `--lowvram` + CPU offload）
- Turbo 4 步 LoRA 加速（实测提速 ~4.4×）
- **SageAttention 注意力加速**：两个 workflow 已内置 `PathchSageAttentionKJ` 节点（Ampere/Ada 约 1.3–2×，不改生成结果）
- **文本编码器显式卸载**：内置 `H3EvictTextEncoder`，编码后立即释放 15.7GB 的 Qwen3-VL，避免采样阶段反复经 PCIe 换入换出
- WebUI + REST API（ComfyUI 原生）
- 内置 [ComfyUI-Copilot](https://github.com/AIDC-AI/ComfyUI-Copilot)：对话式 AI 助手，一句话生成 / 改写 / debug 工作流
- 内置 [Comfy MCP Local](https://github.com/Comfy-Org/comfy-mcp)：在 Claude Code / Cursor 里用自然语言驱动本地 ComfyUI
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

# 4. 构建并启动
docker compose up -d --build
```

> ⚠️ 挂载目录要提前以**你自己的用户**建好：`mkdir -p models output`。若目录不存在，`docker compose` 会以 root 创建，容器内以 uid 1000 运行的 ComfyUI 会写不进去，表现为 SaveVideo 报 `PermissionError: '/opt/ComfyUI/output/video'`，或模型列表为空。

启动完成后访问 http://localhost:8188。默认 `.env.example` 已关闭认证，**直接进入、无需输密码**；若 `WEB_ENABLE_AUTH=true`，则账号固定为 `user`、密码为 `.env` 中的 `WEB_PASSWORD`。

> 可选：仓库带 `pixi.toml`，常用命令可走统一入口——`pixi run up` / `down` / `logs` / `models` / `models-bg` / `mcp-config`。只用原生 `docker compose` 也完全可以。

### 模型下载（可能几小时，支持断点续传）

到 HuggingFace CDN 的连接不稳定（HTTP/2 偶发中断、限速），脚本已强制 HTTP/1.1、开启自动重试与断点续传。后台方式：

```bash
pixi run models-bg       # 后台启动下载，立即返回
pixi run models-status   # 查看各文件已下载大小与日志尾部
pixi run models-logs     # 实时跟踪 .build/models.log
```

脚本会按远端 `content-length` 校验完整性：中断后重跑 `pixi run models-bg` 会从断点接着下，**已下载但未完成的文件不会被误跳**。

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

首次构建要拉 torch cu126 + ComfyUI 依赖 + Copilot 依赖，可能超过一次性前台命令能跑完的时间。Docker 会把已完成的分层写进 BuildKit 缓存，所以拆成「后台启动 + 反复重跑」可以断点续建：

```bash
pixi run build          # 后台启动构建，立即返回；已在跑则直接提示
pixi run build-status   # 查看是否还在跑 + 日志尾部
pixi run build-logs     # 实时跟踪 .build/build.log
pixi run up             # 构建完成后启动容器（镜像已就绪，不再重建）
```

即使进程被环境回收，缓存仍在，重跑 `pixi run build` 会自动从上次完成的分层继续，不会从头再来。只想快速增量构建时也可以直接 `pixi run up-build`。


### 生成视频

1. WebUI 打开模板库（Template Library）→ Video → 选择 `MiniMax H3 Text to Video (T2V)` / `Image to Video (I2V)`
2. 点 Queue 执行，等待输出（右侧 Video 面板可预览/下载）
3. 输出文件同时保存在宿主的 `./output/` 目录

### 加速配置（两个自带 workflow 已调好）

仓库里的 `workflows/minimax_h3_t2v_bund.json` 与 `workflows/minimax_h3_i2v.json` 就是实测的 12GB 配置，容器启动即出现在 WebUI 的 Workflows 列表，已包含：

- `MiniMaxH3TurboLoRA`（`minimax_h3_turbo_v4_step600_ema.safetensors`，4 步）+ `MiniMaxH3TurboSampler`
- `PathchSageAttentionKJ`（ComfyUI-KJNodes）—— 注意力加速，模式默认 `sageattn_qk_int8_pv_fp16_cuda`、`allow_compile` 关闭。这是唯一"不改结果"的提速手段（Ampere/Ada 约 1.3–2×）；若 `sageattention` 未能安装，把模式切回 `disabled` 即可无损回退
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

## AI 辅助：对话式搭 / 改工作流

镜像里已经装好两个 AI 层，都不改动 ComfyUI 本体，随时可回滚。

### 1. ComfyUI-Copilot（WebUI 内的对话侧栏）

打开 WebUI 后，在 Copilot 面板里可以：一句话**生成工作流**、对当前画布**一键 Debug**（自动定位参数/连线错误）、用自然语言**改写**现有工作流、**批量调参**（GenLab）、按描述**推荐节点 / 模型**。

**必须先配一个 LLM**——官方托管 API 已停服，不配 Key 的话只有本地能力可用。两种配法任选：

- **推荐**：编辑 `.env` 后 `docker compose up -d` 重建容器
  ```bash
  CC_OPENAI_BASE_URL=https://api.deepseek.com/v1
  CC_OPENAI_API_KEY=sk-xxxxxxxx
  ```
  （OpenAI 兼容端点均可：DeepSeek / OpenAI / 本地 Ollama、LM Studio。工作流生成可另配 `WORKFLOW_LLM_*`。）
- 或在 WebUI 的 Copilot **Settings** 里直接填 Base URL 与 API Key（保存在浏览器本地，重建容器后可能需要重填）。

> ⚠️ **对 MiniMax H3 的预期要放低**：H3 是较新的模型，Copilot 的知识库基本不认识本项目的 `MiniMaxH3TurboLoRA` / `MiniMaxH3TurboSampler` / `PathchSageAttentionKJ` / `H3EvictTextEncoder` 这套专用节点。实际用法是**让它生成通用骨架**（加载器 / 采样器 / 解码器的连接思路），再手工把 H3 节点替换进去；也可以把官方 H3 模板作为上下文喂给它。别指望它直接吐出能跑的 H3 视频工作流。

### 2. Comfy MCP Local（在 Claude Code / Cursor 里自然语言出片）

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
<summary>备选：把 MCP server 跑在宿主机上（需要额外准备）</summary>

仓库自带 `pixi` 环境，也可以在宿主直接跑：

```bash
pixi install                  # 装 comfy-cli + comfy-mcp
pixi run mcp-config host      # 打印带绝对路径的客户端配置
```

两条注意：① comfy-cli 需要有可用 workspace（宿主没有 ComfyUI 目录时先 `comfy install` 或 `comfy set-default <一个 ComfyUI 检出目录>`）；② 宿主侧的 `COMFYUI_URL` 会指向 `http://127.0.0.1:8188`，也就是 **caddy 那一层**——若 `WEB_ENABLE_AUTH=true` 会直接返回 401，需要先关闭认证。综合考虑，容器模式更省事。

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
| `CC_OPENAI_BASE_URL` | 空 | ComfyUI-Copilot 的聊天 LLM 端点（OpenAI 兼容，如 DeepSeek） |
| `CC_OPENAI_API_KEY` | 空 | ComfyUI-Copilot 的聊天 LLM Key |
| `WORKFLOW_LLM_BASE_URL` / `_API_KEY` / `_MODEL` | 空 | 工作流生成专用模型（可选，不填则复用聊天模型） |
| `COMFY_LOCAL_URL` | `http://127.0.0.1:18188` | 容器内 comfy-cli 连 ComfyUI 的地址（供 Comfy MCP Local 使用） |

模型目录结构（`models/` 挂载进容器 `/workspace/models`）：

```
models/
├── diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors   20.97 GB
├── text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors          15.69 GB
├── vae/minimax_h3_video_vae_fp16.safetensors                            5.21 GB
├── vae/minimax_h3_audio_vae_fp32.safetensors                            0.61 GB
├── loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors      1.96 GB（可选）
└── loras/minimax_h3_turbo_v4_step600_ema.safetensors                    0.78 GB（推荐）
```

## 📊 实测性能（RTX 3060 12GB）

| 配置 | 参数 | 耗时 | 说明 |
|---|---|---|---|
| 官方 8 步（未优化） | 512×288 / 4.46s | ~600s | 首次含 37GB 模型加载 |
| Turbo 4 步 + EasyCache + `--lowvram` | 512×288 / 4.46s | ~136s | 历史实测基线（此配置含 EasyCache，非当前自带 workflow） |
| **Turbo 4 步 + SageAttention + 文本编码器卸载 + `--lowvram`** | 512×288 / 4.46s | 待实测 | 当前自带 workflow 的配置；注意力加速预期再快 1.3–2× 并减少编码器换入换出，未在本仓库单独计时 |

更高分辨率（1344×768 原生画布 / 5s）参考社区实测约 7 分钟/段（Turbo 4 步）。

> 注意：`SageAttention` 只在 Ampere/Ada 及以后有收益（**RTX 30/40 系约 1.3–2×，Blackwell 较小**）；`H3EvictTextEncoder` 在 `--gpu-only` 模式下是 no-op。若 `sageattention` 构建失败，把 `PathchSageAttentionKJ` 切到 `disabled` 即可无损回退。

## 已知限制

1. 12GB 显存为"能跑但慢"的降级配置：权重（~37GB）无法全部驻留显存，推理时 CPU offload，速度受 PCIe 带宽限制
2. v4-600 Turbo LoRA 在 **4 步 + 大幅快速运动**场景偶有 motion-smear，遇到可改用 6-8 步（仍快于官方 20 步）
3. 完整 H3 系统（H3-Context-IR / 2K 再生）为云端 API，未开源；本方案为本地 H3-Base（768p 档）
4. 模型权重遵循 MiniMax H3 社区许可（注意地区限制：排除美/欧/英/韩）
5. **ComfyUI-Copilot 对 H3 的知识有限**：官方托管 API 已停服、必须自备 LLM Key，且其工作流知识库基本不认识 H3/Turbo 专用节点，更适合"生成骨架 + 手工接线"，不是拿来即用的 H3 工作流生成器
6. Copilot 的 `requirements.txt` 会往 ComfyUI 的 Python 环境里引入一批新依赖（`sqlalchemy<2.0`、`openai`、`langsmith`、`modelscope`、`fastmcp` 等），其中 `urllib3>=1.26,<2.0` 可能覆盖上游版本。若与已有插件冲突，可移除 `pip install` 那一步或改装到独立环境
7. Comfy MCP Local 的 `launch_comfyui` / 停止 / 日志类工具语义受限：ComfyUI 在容器内由 ai-dock 启动，comfy-cli 再 `launch` 会另起一个进程。日常用 `run_workflow` / `server_info` / `fetch_outputs` 不受影响
8. `sageattention` 若没有匹配 torch/CUDA 的预编译轮子，会在镜像构建期用 ai-dock 自带的 nvcc 编译（耗时数分钟）。构建脚本对安装失败做了容错，此时把 `PathchSageAttentionKJ` 的模式改为 `disabled` 即可无损回退
9. 自带 workflow **不再内置 EasyCache**：4 步配置下其收益有限且后段可能起颗粒。需要时自行叠加默认参数的 `EasyCache`，且不要与其它缓存节点（如 Spectrum）叠在同一模型分支上

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
| [AIDC-AI/ComfyUI-Copilot](https://github.com/AIDC-AI/ComfyUI-Copilot) | 对话式 AI 工作流助手（容器内安装） |
| [Comfy-Org/comfy-mcp](https://github.com/Comfy-Org/comfy-mcp) | 官方 Comfy MCP Local（容器内安装） |
| [Comfy-Org/comfy-cli](https://github.com/Comfy-Org/comfy-cli) | comfy-mcp 的底层引擎 |
| [Saganaki22/ComfyUI-sol-attn](https://github.com/Saganaki22/ComfyUI-sol-attn) | （可选）Sol-Attn 无损加速，支持 SM86（RTX 30 系） |
| [ModelTC/Minimax-H3-Turbo](https://github.com/ModelTC/Minimax-H3-Turbo) | 4 步蒸馏 LoRA 参考 |

## License

- 本仓库部署脚本/配置：Apache-2.0
- ComfyUI / ai-dock / 各插件：遵循其各自开源许可证
- MiniMax H3 模型权重：MiniMax H3 Community License（注意地区限制）
