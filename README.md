# ComfyUI + MiniMax H3 容器化部署（comfy-h3-container）

在消费级 NVIDIA 显卡（12GB 显存实测可用）上，用 Docker 一键部署 **ComfyUI + MiniMax H3** 本地视频生成（画面 + 原生音频同步生成）。

本项目封装了完整可复现的部署链路：容器镜像定制（含所有踩坑修复）、模型下载脚本、`--lowvram` 低显存优化、Turbo 4 步加速，实测 **512×288 / 4.46s 视频约 136 秒出片**（RTX 3060 12GB）。

## 特性

- Docker 容器化，一条命令启动（`docker compose up -d`）
- 原生支持 MiniMax H3（T2V / I2V / R2V，视频 + 32kHz 立体声音频同步生成）
- 12GB 显存实测可跑（int8 量化 + `--lowvram` + CPU offload）
- Turbo 4 步 LoRA + EasyCache 加速（实测提速 ~4.4×）
- WebUI + REST API（ComfyUI 原生）
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

# 2. 配置密码
cp .env.example .env
# 编辑 .env，修改 WEB_PASSWORD

# 3. 下载模型（约 43GB，支持断点续传）
./scripts/download_models.sh

# 4. 构建并启动
docker compose up -d --build
```

启动完成后访问 http://localhost:8188（账号 `user`，密码为 `.env` 中的 `WEB_PASSWORD`）。

### 生成视频

1. WebUI 打开模板库（Template Library）→ Video → 选择 `MiniMax H3 Text to Video (T2V)` / `Image to Video (I2V)`
2. 点 Queue 执行，等待输出（右侧 Video 面板可预览/下载）
3. 输出文件同时保存在宿主的 `./output/` 目录

### 可选：Turbo 4 步加速工作流

默认模板为 8 步。要使用实测最快的 4 步配置（需要已下载 `minimax_h3_turbo_v4_step600_ema.safetensors`）：

- 在官方 T2V 工作流中把 `UNETLoader` 的输出接入 `MiniMaxH3TurboLoRA` 节点（`lora_name` 选 `minimax_h3_turbo_v4_step600_ema.safetensors`，`low_vram` 开 true）
- 再接入 `EasyCache`（ComfyUI 内置节点，默认参数即可）
- `BasicScheduler` 步数设为 **4**，sampler 用 `MiniMaxH3TurboSampler`

## 配置说明

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `WEB_PASSWORD` | `comfy-h3` | WebUI 访问密码（账号固定 `user`） |
| `COMFYUI_PORT_HOST` | `8188` | 对外端口（caddy 反向代理） |
| `COMFYUI_PORT_LOCAL` | `18188` | 容器内 ComfyUI 监听端口（**不可与 HOST 相同**，否则端口冲突） |
| `COMFYUI_ARGS` | `--listen 0.0.0.0 --lowvram` | ComfyUI 启动参数（`--lowvram` 为 12GB 显存关键优化） |

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
| **Turbo 4 步 + EasyCache + `--lowvram`** | 512×288 / 4.46s | **136s** | 实测最快，显存峰值 11.5GB 无 OOM |

更高分辨率（1344×768 原生画布 / 5s）参考社区实测约 7 分钟/段（Turbo 4 步 + EasyCache）。

## 已知限制

1. 12GB 显存为"能跑但慢"的降级配置：权重（~37GB）无法全部驻留显存，推理时 CPU offload，速度受 PCIe 带宽限制
2. v4-600 Turbo LoRA 在 **4 步 + 大幅快速运动**场景偶有 motion-smear，遇到可改用 6-8 步（仍快于官方 20 步）
3. 完整 H3 系统（H3-Context-IR / 2K 再生）为云端 API，未开源；本方案为本地 H3-Base（768p 档）
4. 模型权重遵循 MiniMax H3 社区许可（注意地区限制：排除美/欧/英/韩）

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
| [Saganaki22/ComfyUI-sol-attn](https://github.com/Saganaki22/ComfyUI-sol-attn) | （可选）Sol-Attn 无损加速，支持 SM86（RTX 30 系） |
| [ModelTC/Minimax-H3-Turbo](https://github.com/ModelTC/Minimax-H3-Turbo) | 4 步蒸馏 LoRA 参考 |

## License

- 本仓库部署脚本/配置：Apache-2.0
- ComfyUI / ai-dock / 各插件：遵循其各自开源许可证
- MiniMax H3 模型权重：MiniMax H3 Community License（注意地区限制）
