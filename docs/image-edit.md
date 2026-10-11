# 修图：Qwen-Image-Edit（阿里指令式改图，GGUF / 12GB 显存可跑）

前面 SDXL 那条链路只会「凭空出图」（文生图）。要**改一张已有的图** —— 换背景、改光线、去路人、换装、换材质、改图中文字、两张图融合 —— 用阿里 **Qwen-Image-Edit-2511**：给一张图 + 一句中文指令，它按指令重画这张图，同时尽量保住原图的人物、构图与风格。做游戏素材时返修立绘 / 场景图最省事。

| 工作流 | 采样参数 | 用途 |
|---|---|---|
| `qwen_image_edit_gguf_lightning.json` | 4 步 / CFG 1.0（Lightning 4 步 LoRA） | **批量出素材推荐**，一次采样快得多 |
| `qwen_image_edit_gguf.json` | 20 步 / CFG 4.0 | 质量档，无 LoRA，最接近官方权重行为 |

两个工作流都在画布左上角贴了 `MarkdownNote`（用法 / 指令示例 / 12GB 提示），接线一致：`Load Image` → 指令 → `KSampler` → `Save Image`，输出在 `output/qwen_edit/`。

## 1. 为什么这条链路要重建镜像（本仓库唯一需要重建镜像的生图功能）

Qwen-Image-Edit-2511 是 **20B** 模型，Comfy-Org 官方权重 fp8/int8 就有 20.5GB、bf16 40.9GB —— **12GB 显存装不下**，显存不够时连加载都会 OOM。低显存只有一条现实的路：**GGUF 量化**（Q3_K_S 9.2GB / Q4_K_S 12.4GB）+ 镜像里已经默认开启的 `--lowvram` + CPU offload。

GGUF 需要 `ComfyUI-GGUF` 自定义节点（提供 `Unet Loader (GGUF)` / `CLIPLoader (GGUF)`），所以 Dockerfile 里加了一步 clone（顺带装了 `gguf` / `sentencepiece` / `protobuf` 依赖）：

```bash
pixi run build && pixi run build-status   # 或直接：pixi run up-build
pixi run up
```

> 「纯 fp8/int8、不重建镜像」也能接，但那是给 16GB+ 显存的方案：把官方 `qwen_image_edit_2511_fp8mixed.safetensors`（20.5GB）+ `qwen_2.5_vl_7b_fp8_scaled.safetensors`（9.4GB）放好，用原生 `Unet Loader` / `CLIP Loader` 即可，本仓库不放这类工作流。

## 2. 下载权重（约 16GB）

```bash
pixi run models-qwen-edit        # 魔搭下载，支持断点续传
```

下什么、放哪（完整清单见 [models.md](models.md#qwen-edit--qwen-image-edit-修图链路约-16gb)）：

| 文件 | 大小 | 目录 | 用途 |
|---|---|---|---|
| `qwen-image-edit-2511-Q3_K_S.gguf` | 9.2GB | `diffusion_models/` | 主模型（默认量化档） |
| `Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf` | 4.7GB | `text_encoders/` | 文本编码器（懂中文指令） |
| `Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf` | 1.3GB | `text_encoders/` | 上面这个编码器的**视觉塔**，缺了会坏 |
| `qwen_image_vae.safetensors` | 0.25GB | `vae/` | VAE |
| `Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors` | 0.81GB | `loras/` | 4 步加速 LoRA |

> **mmproj 是这条链路最容易踩的坑**：ComfyUI-GGUF 加载 `qwen2vl` 文本编码器时，会在同目录按「文件名包含编码器基名」的规则找 `mmproj*.gguf`。上游 unsloth 的文件名就叫 `mmproj-F16.gguf`（不含模型名），匹配不上就会在日志里刷 `Can't find mmproj file ... Qwen-Image-Edit will be broken!`、参考图被当成没有。下载脚本已经把它落盘成 `Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf`，不用手动改。

量化档按显存 / 内存挑（`QWEN_EDIT_QUANT=... pixi run models-qwen-edit`）：

| 档位 | 主模型 | 说明 |
|---|---|---|
| `Q3_K_S`（默认） | 9.2GB | 12GB 显存上最稳，质量够做素材返修 |
| `Q4_0` / `Q4_K_S` | 11.9 / 12.4GB | 画质更好，更吃内存与 offload，速度更慢 |
| `Q5_K_M` / `Q6_K` | 15.0 / 16.9GB | 16GB+ 显存再考虑 |

## 3. 怎么用

1. WebUI 左侧 **Workflows** 选 `qwen_image_edit_gguf_lightning`（快）或 `qwen_image_edit_gguf`（质量）
2. 点 `图 1：要修改的图` 的 upload，选一张图
3. 在 `修改指令（中文即可）` 里写一句话
4. 点 Queue，输出在 `output/qwen_edit/edited_*.png`

指令直接写中文就行（文本编码器是 Qwen2.5-VL）。几个实测好用的句式：

| 想要的效果 | 指令写法 |
|---|---|
| 换光线 / 时段 | `把白天改成黄昏，加暖色逆光，其它保持不变` |
| 去杂物 / 去路人 | `去掉左下角的路人，保持背景连续` |
| 换装 / 换配色 | `把校服换成红色夹克，保留角色长相与姿势` |
| 改图中文字 | `把招牌上的文字改成 OPEN，字体风格不变` |
| 换画风 | `改成 90 年代赛璐璐动画上色风格` |
| 两图融合 | 把 `图 2` 的输出拖到两个 `Text Encode Qwen Image Edit Plus` 的 `image2`，指令写 `把图 1 的沙发材质换成图 2 的毛皮材质` |

**换姿势 / 换角度、需要严格构图控制时它不擅长**：那是 SDXL + ControlNet（OpenPose）的活；纯去杂物 / 修手也可以先用 SDXL 的 inpaint 链路（零下载），按需挑。

## 4. 12GB 显存上的预期与调参

- 首次 Queue 要加载 9.2GB 主模型 + 4.7GB 文本编码器再 offload，**加载阶段就慢**，属正常
- 出图速度：20B 模型在 12GB 卡上比 SDXL 慢一个量级。批量做素材用 Lightning 4 步档；质量档（20 步）留给单张精修
- 内存：`docker-compose.yml` 里 `memory: 24G` 对 9.2GB 主模型 + 文本编码器的 offload 偏紧，跑不动先把这个上限调高（`.env` 或 compose 里改）
- `--lowvram` 已在镜像默认参数里，**不要**改成 `--gpu-only`
- 画质档想再提：把 KSampler 步数从 20 提到 40（官方 Qwen 推荐值），速度更慢

> 这一节的具体耗时数字**本仓库没有 12GB 显卡上的实测**：链路、权重、参数都按官方 2511 模板与 ComfyUI 源码核对过（节点名、接线、量化档大小），但速度与稳定性请以你自己机器为准；跑不动先降量化档（`QWEN_EDIT_QUANT=Q3_K_S`）、调高内存上限。

## 5. 换 fp8 文本编码器（可选，免 mmproj）

不想用 GGUF 文本编码器（或想对比效果）：

```bash
QWEN_EDIT_TEXT_ENC=fp8 pixi run models-qwen-edit   # 额外下 9.4GB qwen_2.5_vl_7b_fp8_scaled.safetensors
# 或两种都下：QWEN_EDIT_TEXT_ENC=both
```

然后把工作流里的 `CLIPLoader (GGUF)` 换成原生 `CLIP Loader`（type 仍选 `qwen_image`），选中 `qwen_2.5_vl_7b_fp8_scaled.safetensors` 即可 —— 原生加载器不需要 mmproj，但显存占用更大。

## 6. 许可

Qwen-Image-Edit-2511 及本链路用到的 GGUF 量化（unsloth）、Lightning LoRA（lightx2v）、文本编码器（Qwen2.5-VL-7B）**均为 Apache-2.0，允许商用**（含游戏素材），需随附许可副本并遵守其条款；生成内容责任在使用者。权重来源（魔搭均有同名仓库，下载脚本默认走魔搭）：[Qwen/Qwen-Image-Edit-2511](https://modelscope.cn/models/Qwen/Qwen-Image-Edit-2511)、[unsloth/Qwen-Image-Edit-2511-GGUF](https://modelscope.cn/models/unsloth/Qwen-Image-Edit-2511-GGUF)、[lightx2v/Qwen-Image-Edit-2511-Lightning](https://modelscope.cn/models/lightx2v/Qwen-Image-Edit-2511-Lightning)、[Comfy-Org/Qwen-Image_ComfyUI](https://modelscope.cn/models/Comfy-Org/Qwen-Image_ComfyUI)。
