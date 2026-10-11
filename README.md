# ComfyUI + MiniMax H3 容器化部署（comfy-h3-container）

在消费级 NVIDIA 显卡（12GB 显存实测可用）上，用 Docker 一键部署 **ComfyUI + MiniMax H3** 本地视频生成（画面 + 原生音频同步生成）。

本项目封装了完整可复现的部署链路：容器镜像定制（含所有踩坑修复）、模型下载脚本、`--lowvram` 低显存优化、Turbo 4 步加速、SageAttention 注意力加速与文本编码器显式卸载，实测 **608×352 / 2.33s 视频约 79 秒出片**（RTX 3060 12GB）。

详细文档在 [`docs/`](docs/README.md)。

## 特性

- Docker 容器化，一条命令启动（`docker compose up -d`）
- 原生支持 MiniMax H3（T2V / I2V / R2V，视频 + 32kHz 立体声音频同步生成）
- **参考生视频（R2V）**：最多 9 张参考图 / 3 段参考视频 / 3 段参考音频，锁定人物长相、风格、动作、运镜、音色（多视角人物图防「长相抖动」就靠它）
- **动作控制（Fun ControlNet Union）**：用姿态 / 深度 / 边缘 / HED / MLSD 控制视频驱动画面（内置 SDPose 从舞蹈视频提骨架），也支持 mask 局部重绘
- **多帧参考（Multiframe Reference）**：在时间轴任意帧锚定参考图或音频
- 12GB 显存实测可跑（int8 量化 + `--lowvram` + CPU offload）
- Turbo 4 步 LoRA 加速（实测提速 ~4.4×）
- **SageAttention 注意力加速**：两个 workflow 已内置 `PathchSageAttentionKJ` 节点（Ampere/Ada 约 1.3–2×，不改生成结果）
- **文本编码器显式卸载**：内置 `H3EvictTextEncoder`，编码后立即释放 15.7GB 的 Qwen3-VL，避免采样阶段反复经 PCIe 换入换出
- WebUI + REST API（ComfyUI 原生）
- 内置 [artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp)：让 Agent **直接搭建 / 编辑 / 校验工作流**；作为容器内服务由 supervisord 托管（Streamable HTTP，宿主 9100），日志与 ComfyUI / caddy 一起进 `docker logs`
- **二次元生图（galgame 素材）**：内置 3 个 SDXL 动漫底模工作流 —— 场景图（背景）、9 向人物设定表（单图 3×3）、9 向人物分向单图（同 seed 一次出 9 张），配套 `pixi run models image` 一键下底模，全部是 ComfyUI 原生节点、**不用重建镜像**
- **修图 / 改图（阿里 Qwen-Image-Edit 2511）**：内置 2 个 GGUF 修图工作流（4 步 Lightning 加速档 / 20 步质量档），中文一句话改图 —— 换背景、改光线、去路人、换装、改图中文字、两图融合；配套 `pixi run models qwen-edit` 一键下权重（GGUF 量化 + `--lowvram` 让 20B 模型跑在 12GB 显存上）。这条链路多装一个 ComfyUI-GGUF 节点，**需要重建镜像**
- WebUI 认证可一键关闭（局域网自用、免每次输密码）
- 模型一键下载（魔搭源、断点续传、已下载自动跳过）

## 硬件要求

| 项目 | 最低 | 推荐 |
|---|---|---|
| GPU | NVIDIA 12GB 显存（RTX 3060 实测） | 24GB+ 显存（更快、可跑更高分辨率） |
| 系统内存 | 32GB | 64GB（offload 稳定） |
| 磁盘 | 45GB 可用（二次元生图另加约 7GB，Qwen 修图另加约 16GB） | NVMe SSD |
| 软件 | Docker + nvidia-container-toolkit | Linux / WSL2 |

> 非 NVIDIA（AMD ROCm / Apple Silicon）请参考社区方案。

## 内部包含的模型

镜像本身**不含**模型权重，全部由宿主侧脚本从**魔搭 ModelScope** 下载到 `models/`（容器内 `/workspace/models`）。只有一个下载脚本 `scripts/download_models.sh`、也只有一个 pixi 任务 `models`，模块名作为参数传入，**不带参数默认下载全部**：

| 模块 | 内容 | 大小 | 下载 |
|---|---|---|---|
| base | H3 文生 / 图生视频主模型（fl2va int8）+ Qwen3-VL 文本编码器 + 视频 / 音频 VAE + Turbo LoRA | 约 43GB | `pixi run models base` |
| extra | 参考生视频主模型（ref2va）+ Fun ControlNet 控制补丁 + R2V Turbo LoRA + SDPose 姿态提取 | 约 25GB | `pixi run models extra` |
| image | 二次元插画底模 Illustrious XL v2.0（默认）/ Animagine XL 4.0（SDXL，单文件 checkpoint） | 约 6.9GB | `pixi run models image` |
| qwen-edit | Qwen-Image-Edit-2511 修图链路（GGUF 主模型 + Qwen2.5-VL 文本编码器 + mmproj + VAE + 4 步 LoRA） | 约 16GB | `pixi run models qwen-edit` |

```bash
pixi run models                 # 不带参数 = all：上面全部，约 91GB（默认）
pixi run models base            # 基础视频模型，约 43GB
pixi run models extra           # 参考 / 控制模型，约 25GB
pixi run models image           # 二次元插画底模，约 6.9GB
pixi run models qwen-edit       # Qwen 修图链路，约 16GB
IMAGE_MODELS=all pixi run models image                      # 两个二次元底模都下
QWEN_EDIT_QUANT=Q4_K_S pixi run models qwen-edit            # 修图主模型换 12.4GB 画质档
MODELS_DIR=/data/ai-models/comfy-h3 pixi run models base    # 下到外部大盘
```

已下载完整的文件会自动跳过（不重复占流量），中断后重跑从断点续传。下载量大，建议放在 `tmux` 里跑，或按 [docs/models.md](docs/models.md#1-下载入口) 里的方式自行放后台。

每个模块包含哪些文件、放在哪个目录、各自什么用途，以及完整模型目录结构，见 [docs/models.md](docs/models.md)。

## 使用方式

### 1. 起步

```bash
git clone https://github.com/SilenWang/comfy-h3-container.git
cd comfy-h3-container

mkdir -p models output              # 挂载目录要先以自己的用户建好（见下）

cp .env.example .env                # 默认已 WEB_ENABLE_AUTH=false（免密码访问）
pixi run models base                # 下载视频模型（约 43GB，魔搭源，支持断点续传；不带参数则下全部，约 91GB）

docker compose up -d --build        # 构建并启动；或 pixi run build && pixi run up
```

访问 <http://localhost:8188>（默认免密；若开了认证，账号固定 `user`、密码见 `.env` 的 `WEB_PASSWORD`）。

> ⚠️ 挂载目录不存在时 Docker 会以 root 创建，容器内以 uid 1000 运行的 ComfyUI 写不进去，表现为 SaveVideo 报 `PermissionError: '/opt/ComfyUI/output/video'`，或模型列表为空。

常用命令（`pixi run` 与原生 `docker compose` 等价，不用 pixi 也可以）：

```bash
pixi run up / down / restart / logs     # 容器运维
pixi run build && pixi run build-status # 后台构建（可断点续建，首次构建耗时长时推荐）
pixi run up-build                       # 前台构建并启动（增量构建快）
pixi run fix-sage-attn                  # 容器内现场补装 SageAttention，无需重建镜像
pixi run mcp-config                     # 打印 MCP 客户端配置片段
```

### 2. 视频生成

WebUI 左侧 **Workflows** 选模板 → 点 **Queue** → 输出落在 `./output/`：

| 模板 | 用途 |
|---|---|
| `minimax_h3_t2v_bund` | 文生视频 |
| `minimax_h3_i2v` | 图生视频 |
| `minimax_h3_r2v` | 参考生视频（多视角人物一致性） |
| `minimax_h3_fun_controlnet_union` | 动作控制（姿态 / 深度 / 边缘） |
| `minimax_h3_multiframe_reference` | 多帧参考（时间轴锚点） |

自带模板已调好 12GB 配置（Turbo 4 步 + SageAttention + 文本编码器卸载 + `--lowvram`）；加速原理、接线拓扑与 EasyCache 取舍见 [docs/video.md](docs/video.md)。后三种参考玩法要先下额外模型（约 25GB，`pixi run models extra`），细节见 [docs/video-reference.md](docs/video-reference.md)。

### 3. 生成图片（二次元插画）

```bash
pixi run models image      # 下底模（约 6.9GB）
```

再用 `anime_scene_t2i`（场景图 / galgame 背景）、`anime_character_sheet`（单图 3×3 设定表）、`anime_character_9views`（同 seed 出 9 张分向单图）三个工作流，用法、prompt 骨架与 tag 清单见 [docs/image-anime.md](docs/image-anime.md)。

### 4. 修图（Qwen-Image-Edit）

```bash
pixi run models qwen-edit      # 下权重（约 16GB，GGUF）
```

这条链路需要先重建镜像（多一个 ComfyUI-GGUF 节点）。之后用 `qwen_image_edit_gguf_lightning`（4 步，批量出素材）或 `qwen_image_edit_gguf`（20 步，质量档），给一张图 + 一句中文指令即可改图。细节见 [docs/image-edit.md](docs/image-edit.md)。

### 5. AI 辅助：用 MCP 驱动 ComfyUI

容器内已托管 [artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp)（随容器启动，Streamable HTTP，宿主 9100），Agent 可直接搭建 / 编辑 / 校验工作流：

```bash
pixi run mcp-config        # 打印 Claude Code / Desktop / Cursor 的配置片段
```

端点选择（本机 / 同机其他容器 / 局域网）、鉴权令牌与安全提醒见 [docs/mcp.md](docs/mcp.md)。

### 更多文档

| 文档 | 内容 |
|---|---|
| [docs/deployment.md](docs/deployment.md) | 目录准备、构建（后台续建）、容器运维、外部模型目录 |
| [docs/models.md](docs/models.md) | 模型清单、下载开关、模型目录结构、模型许可 |
| [docs/configuration.md](docs/configuration.md) | 环境变量表、WebUI 认证 |
| [docs/performance.md](docs/performance.md) | 实测性能 |
| [docs/limitations.md](docs/limitations.md) | 已知限制 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 故障排查 |

## 项目参考与致谢

本项目为以下开源项目的整合与容器化封装，**衷心感谢**各项目作者：

| 项目 | 用途 |
|---|---|
| [ai-dock/comfyui](https://github.com/ai-dock/comfyui) | 容器基础镜像（ComfyUI Docker 方案） |
| [Comfy-Org/ComfyUI](https://github.com/Comfy-Org/ComfyUI) | ComfyUI 本体（≥0.30 原生支持 MiniMax H3） |
| [MiniMax-AI/MiniMax-H3](https://github.com/MiniMax-AI/MiniMax-H3) | MiniMax H3 官方模型与文档 |
| [Comfy-Org/MiniMax-H3](https://modelscope.cn/models/Comfy-Org/MiniMax-H3) | 量化模型权重（int8 剪枝 + nvfp4-AWQ，适配消费级显卡） |
| [shiqikuangsan31/MiniMax-H3-12GB-ComfyUI-Guide](https://github.com/shiqikuangsan31/MiniMax-H3-12GB-ComfyUI-Guide) | 12GB 显存优化方案（`--lowvram`、Turbo 4 步 + EasyCache 实测数据） |
| [larryvrh/ComfyUI-MiniMax-H3-Turbo](https://github.com/larryvrh/ComfyUI-MiniMax-H3-Turbo) | Turbo LoRA 节点插件 |
| [larryvrh/MiniMax-H3-Turbo-Lora](https://modelscope.cn/models/larryvrh/MiniMax-H3-Turbo-Lora) | v4-600 Turbo LoRA 权重 |
| [kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) | `PathchSageAttentionKJ` 注意力加速节点（+ `sageattention`） |
| [matlowai/ComfyUI-MAINodes](https://github.com/matlowai/ComfyUI-MAINodes) | `H3EvictTextEncoder` 编码后卸载文本编码器节点 |
| [artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp) | 容器内托管 MCP：让 Agent 搭建 / 编辑工作流（Streamable HTTP） |
| [Saganaki22/ComfyUI-sol-attn](https://github.com/Saganaki22/ComfyUI-sol-attn) | （可选）Sol-Attn 无损加速，支持 SM86（RTX 30 系） |
| [ModelTC/Minimax-H3-Turbo](https://github.com/ModelTC/Minimax-H3-Turbo) | 4 步蒸馏 LoRA 参考 |
| [OnomaAIResearch/Illustrious-XL-v2.0](https://modelscope.cn/models/OnomaAIResearch/Illustrious-XL-v2.0) | 二次元生图默认底模（SDXL 动漫 checkpoint） |
| [cagliostrolab/animagine-xl-4.0](https://modelscope.cn/models/cagliostrolab/animagine-xl-4.0) | 二次元生图备用底模（插画质感 / 光影） |
| [city96/ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) | GGUF 量化加载节点（`Unet Loader (GGUF)` / `CLIPLoader (GGUF)`），让 Qwen-Image-Edit 跑进 12GB 显存 |
| [Qwen/Qwen-Image-Edit-2511](https://modelscope.cn/models/Qwen/Qwen-Image-Edit-2511) | 修图主模型（阿里指令式图像编辑，Apache-2.0） |
| [unsloth/Qwen-Image-Edit-2511-GGUF](https://modelscope.cn/models/unsloth/Qwen-Image-Edit-2511-GGUF) · [unsloth/Qwen2.5-VL-7B-Instruct-GGUF](https://modelscope.cn/models/unsloth/Qwen2.5-VL-7B-Instruct-GGUF) | 修图链路 GGUF 量化权重（主模型 + 文本编码器 + mmproj） |
| [lightx2v/Qwen-Image-Edit-2511-Lightning](https://modelscope.cn/models/lightx2v/Qwen-Image-Edit-2511-Lightning) | 4 步加速 LoRA（20 步 → 4 步） |
| [Comfy-Org/Qwen-Image_ComfyUI](https://modelscope.cn/models/Comfy-Org/Qwen-Image_ComfyUI) | Qwen-Image VAE / fp8 文本编码器权重 |

## License

- 本仓库部署脚本 / 配置：Apache-2.0
- ComfyUI / ai-dock / 各插件：遵循其各自开源许可证
- MiniMax H3 模型权重：MiniMax H3 Community License（注意地区限制：排除美 / 欧 / 英 / 韩）
- 二次元生图底模权重：Illustrious XL v2.0（CreativeML OpenRAIL-M）/ Animagine XL 4.0（OpenRAIL++-M），允许商用，须遵守各自许可的使用限制条款
- Qwen-Image-Edit-2511 修图链路权重（主模型、GGUF 量化、Lightning LoRA、Qwen2.5-VL 文本编码器）：Apache-2.0，允许商用（含游戏素材），须随附许可副本并遵守其条款
