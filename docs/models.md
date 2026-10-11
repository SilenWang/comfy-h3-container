# 模型清单与下载

## 1. 下载入口

只有**一个**下载脚本 `scripts/download_models.sh`，按类别下载对应模型；下载源固定为**魔搭 ModelScope**，不走 HuggingFace。

```bash
bash scripts/download_models.sh            # 等价于 base
bash scripts/download_models.sh base       # 基础视频模型（T2V / I2V / 首尾帧），约 43GB
bash scripts/download_models.sh extra      # 参考 / 控制模型（R2V + 动作控制），约 25GB
bash scripts/download_models.sh image      # 二次元插画底模（SDXL），约 6.9GB
bash scripts/download_models.sh qwen-edit  # Qwen-Image-Edit 修图链路（GGUF），约 16GB
bash scripts/download_models.sh all        # 上面全部，约 91GB
```

走 pixi 时同一个脚本：

| 命令 | 类别 | 大小 |
|---|---|---|
| `pixi run models` | base（默认） | 约 43GB |
| `pixi run models-extra` | extra | 约 25GB |
| `pixi run models-image` | image | 约 6.9GB |
| `pixi run models-qwen-edit` | qwen-edit | 约 16GB |
| `pixi run models extra` / `image` / `qwen-edit` / `all` | 同上（类别直接作为参数） | — |

> 下载量大（base 约 43GB），建议在 `tmux` / `screen` 里跑，或自行放后台：
> `nohup bash scripts/download_models.sh > models.log 2>&1 &`。本仓库不再提供后台 / 状态查询任务。

### 断点续传与跳过

- **已下载完整**（本地大小 == 远端大小）的文件直接 `SKIP (complete)`，不重复占流量；
- **下了一半**的文件从断点续传（`curl -C -`），中断后重跑接着下；
- 传输卡死（<1MB/s 持续 60s）会自动断开交给重试，掉线最多重试 100 次。

### 可选环境变量

| 变量 | 默认 | 适用类别 | 说明 |
|---|---|---|---|
| `MODELS_DIR` | `./models` | 全部 | 模型目录（与 compose 的挂载一致），可指向外部大盘 |
| `IMAGE_MODELS` | `illustrious` | image | `illustrious` / `animagine` / `all` |
| `QWEN_EDIT_QUANT` | `Q3_K_S` | qwen-edit | 主模型量化档：`Q3_K_S`(9.2GB) / `Q4_0` / `Q4_K_S`(12.4GB) / `Q5_K_M` / `Q6_K` |
| `QWEN_EDIT_TEXT_QUANT` | `Q4_K_M` | qwen-edit | 文本编码器量化档 |
| `QWEN_EDIT_TEXT_ENC` | `gguf` | qwen-edit | 文本编码器形式：`gguf` / `fp8` / `both` |
| `QWEN_EDIT_LIGHTNING` | `1` | qwen-edit | 是否下 4 步 Lightning LoRA，设 `0` 跳过 |

示例：

```bash
IMAGE_MODELS=all pixi run models-image                                  # 两个二次元底模都下
QWEN_EDIT_QUANT=Q4_K_S pixi run models-qwen-edit                        # 修图主模型换 12.4GB 画质档
QWEN_EDIT_TEXT_ENC=fp8 pixi run models-qwen-edit                        # 文本编码器换 fp8（免 mmproj）
MODELS_DIR=/data/ai-models/comfy-h3 pixi run models                     # 下到外部目录
```

## 2. 模型类别与文件清单

### base — 基础视频模型（约 43GB）

T2V / I2V / 首尾帧所需的 MiniMax H3 基础权重，来自魔搭 `Comfy-Org/MiniMax-H3` 与 `larryvrh/MiniMax-H3-Turbo-Lora`。

| 文件 | 大小 | 目录 | 用途 |
|---|---|---|---|
| `minimax_h3_fl2va_pruned_int8_convrot.safetensors` | 20.97GB | `diffusion_models/` | 主模型（FL2VA，int8 剪枝） |
| `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | 15.69GB | `text_encoders/` | 文本编码器（Qwen3-VL 32B，nvfp4-AWQ） |
| `minimax_h3_video_vae_fp16.safetensors` | 5.21GB | `vae/` | 视频 VAE |
| `minimax_h3_audio_vae_fp32.safetensors` | 0.61GB | `vae/` | 音频 VAE |
| `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors` | 1.96GB | `loras/` | 官方 8 步 Turbo LoRA（可选） |
| `minimax_h3_turbo_v4_step600_ema.safetensors` | 0.78GB | `loras/` | v4-600 Turbo LoRA，**自带工作流默认用它（4 步）** |

### extra — 参考 / 控制模型（约 25GB）

只有用 R2V 参考生视频 / Fun ControlNet 动作控制 / 多帧参考时才需要，来自魔搭 `Comfy-Org/MiniMax-H3` 与 `Comfy-Org/SDPose`。

| 文件 | 大小 | 目录 | 用途 |
|---|---|---|---|
| `minimax_h3_ref2va_pruned_int8_convrot.safetensors` | 19.53GB | `diffusion_models/` | 参考生视频主模型（ref2va，与 T2V/I2V 的 fl2va 不通用） |
| `minimax_h3_fun_controlnet_union_pruned_int8_convrot.safetensors` | 2.14GB | `model_patches/` | Fun ControlNet Union 控制补丁（Canny / Depth / HED / MLSD / Pose） |
| `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors` | 1.82GB | `loras/` | R2V 的 4 步 Turbo LoRA（可选） |
| `sdpose_wholebody_fp16.safetensors` | 1.79GB | `checkpoints/` | SDPose 姿态提取 |
| `rt_detr_v4-x-hgnet_fp16.safetensors` | 0.12GB | `diffusion_models/` | SDPose 的人体检测器 |

### image — 二次元插画底模（约 6.9GB / 个）

SDXL 动漫底模，单文件 checkpoint，来自魔搭 `OnomaAIResearch/Illustrious-XL-v2.0` 与 `cagliostrolab/animagine-xl-4.0`。

| 文件 | 大小 | 目录 | 说明 |
|---|---|---|---|
| `illustrious-xl-v2.0.safetensors` | 6.94GB | `checkpoints/` | 默认底模，Danbooru tag 遵循度好，人物设定 / 立绘稳 |
| `animagine-xl-4.0.safetensors` | 6.94GB | `checkpoints/` | 可选（`IMAGE_MODELS=animagine`），插画质感 / 光影更强 |

用法见 [image-anime.md](image-anime.md)。

### qwen-edit — Qwen-Image-Edit 修图链路（约 16GB）

GGUF 量化链路，来自魔搭 `unsloth/Qwen-Image-Edit-2511-GGUF`、`unsloth/Qwen2.5-VL-7B-Instruct-GGUF`、`Comfy-Org/Qwen-Image_ComfyUI`、`lightx2v/Qwen-Image-Edit-2511-Lightning`。

| 文件 | 大小 | 目录 | 用途 |
|---|---|---|---|
| `qwen-image-edit-2511-Q3_K_S.gguf` | 9.22GB | `diffusion_models/` | 主模型（默认量化档 `Q3_K_S`） |
| `Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf` | 4.68GB | `text_encoders/` | 文本编码器（懂中文指令） |
| `Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf` | 1.35GB | `text_encoders/` | 上面这个编码器的**视觉塔**，缺了会坏 |
| `qwen_image_vae.safetensors` | 0.25GB | `vae/` | VAE |
| `Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors` | 0.81GB | `loras/` | 4 步加速 LoRA |
| `qwen_2.5_vl_7b_fp8_scaled.safetensors` | 9.40GB | `text_encoders/` | 可选（`QWEN_EDIT_TEXT_ENC=fp8`），原生 CLIPLoader 用，免 mmproj |

> **mmproj 是这条链路最容易踩的坑**：ComfyUI-GGUF 加载 `qwen2vl` 文本编码器时，会在同目录按「文件名包含编码器基名」的规则找 `mmproj*.gguf`。上游 unsloth 的文件名就叫 `mmproj-F16.gguf`（不含模型名），匹配不上就会在日志里刷 `Can't find mmproj file ... Qwen-Image-Edit will be broken!`、参考图被当成没有。下载脚本已经把它落盘成 `Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf`，不用手动改。

用量化档 / 换编码器的取舍与用法见 [image-edit.md](image-edit.md)。

## 3. 模型目录结构

`models/` 挂载进容器 `/workspace/models`，子目录由 `extra_model_paths.yaml` 映射成 ComfyUI 的各模型搜索路径：

```
models/
├── diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors   20.97 GB
├── text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors          15.69 GB
├── vae/minimax_h3_video_vae_fp16.safetensors                            5.21 GB
├── vae/minimax_h3_audio_vae_fp32.safetensors                            0.61 GB
├── loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors      1.96 GB（可选）
├── loras/minimax_h3_turbo_v4_step600_ema.safetensors                    0.78 GB（推荐）
├── checkpoints/illustrious-xl-v2.0.safetensors                          6.94 GB（二次元生图底模，默认）
├── checkpoints/animagine-xl-4.0.safetensors                             6.94 GB（二次元生图底模，可选）
├── diffusion_models/qwen-image-edit-2511-Q3_K_S.gguf                    9.22 GB（Qwen 修图主模型，GGUF，可选）
├── text_encoders/Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf                     4.68 GB（Qwen 修图文本编码器，可选）
├── text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf                 1.35 GB（视觉塔，缺了 Qwen 修图会坏）
├── vae/qwen_image_vae.safetensors                                       0.25 GB（Qwen 修图 VAE）
├── loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors    0.81 GB（Qwen 修图 4 步加速，可选）
├── diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors  19.53 GB（R2V，额外）
├── loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors     1.82 GB（R2V Turbo，额外）
├── model_patches/minimax_h3_fun_controlnet_union_pruned_int8_convrot…  2.14 GB（动作控制，额外）
├── checkpoints/sdpose_wholebody_fp16.safetensors                        1.79 GB（姿态提取，额外）
└── diffusion_models/rt_detr_v4-x-hgnet_fp16.safetensors                 0.12 GB（SDPose 检测器，额外）
```

> 二次元生图底模用 `pixi run models-image` 下载，只做 T2V / I2V 不必装；Qwen 修图那几项用 `pixi run models-qwen-edit` 下载，只做视频 / 文生图不必装；最后 5 项（约 25GB）仅 R2V / 动作控制 / 多帧参考需要，用 `pixi run models-extra` 下载。

## 4. 模型许可

| 模型 | 许可 |
|---|---|
| MiniMax H3 权重（base / extra） | MiniMax H3 Community License（注意地区限制：排除美 / 欧 / 英 / 韩） |
| Illustrious XL v2.0 | CreativeML OpenRAIL-M，允许商用 |
| Animagine XL 4.0 | CreativeML OpenRAIL++-M，允许商用 |
| Qwen-Image-Edit-2511 链路（主模型 / GGUF 量化 / Lightning LoRA / Qwen2.5-VL 文本编码器） | Apache-2.0，允许商用（含游戏素材） |

具体要求（随附许可副本、保留出处、使用限制条款）见 [README 的许可章节](../README.md#license)。
