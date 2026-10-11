# 生成图片：二次元插画（场景图 / 9 向人物设定素材）

容器默认只带视频工作流。二次元出图 = **SDXL 动漫底模 + 仓库自带的三个工作流**，全部用 ComfyUI 核心节点（`CheckpointLoaderSimple` / `CLIPTextEncode` / `KSampler` / `LatentUpscale` / `SaveImage` / `PrimitiveInt` / `Concatenate Text`，ComfyUI ≥ 0.35 即可，本镜像构建时拉最新 master），**不需要重建镜像**，容器启动即出现在 WebUI 的 Workflows 列表里。

| 工作流 | 产出 | 默认尺寸 | 说明 |
|---|---|---|---|
| `anime_scene_t2i.json` | 场景图 / galgame 背景 | 1216×832，含 1.5× 二段放大 | `no humans` 纯背景；画布上贴了场景 / 时间 / 光效 / 构图 tag 清单 |
| `anime_character_sheet.json` | 9 向人物设定表（单图 3×3） | 1024×1024，含 1.5× 二段放大 | 一张图 9 格视角，人物一致性最好，适合角色定稿 / 美术参考图 |
| `anime_character_9views.json` | 9 向人物分向单图 ×9 | 832×1216 ×9 | 同一 seed + 同一潜空间，只换视角提示词；9 张独立 PNG，可直接当立绘 / 设定素材 |

三个工作流都在画布左上角贴了 `MarkdownNote` 说明节点（用法 / prompt 骨架 / tag 清单），照着手改就行。

## 1. 先下底模（约 6.9GB）

```bash
pixi run models-image           # 默认 Illustrious XL v2.0，魔搭下载，支持断点续传
```

底模落在 `models/checkpoints/`（`MODELS_DIR` 同样生效，可直接下到外部大盘）。换 / 加底模：

```bash
IMAGE_MODELS=animagine pixi run models-image    # Animagine XL 4.0：插画质感与光影更好
IMAGE_MODELS=all pixi run models-image          # 两个都下（约 13.9GB）
```

工作流默认加载 `illustrious-xl-v2.0.safetensors`；想用另一个底模，把 `Load Checkpoint` 节点的 `ckpt_name` 改成 `animagine-xl-4.0.safetensors` 即可（每个工作流各有一处）。

## 2. 场景图（galgame 背景）

打开 `anime_scene_t2i.json`，改 `Prompt (Scene)` 后 Queue，输出在 `output/anime/scene/`。

prompt 骨架（Danbooru tag 风格，逗号分隔，`no humans` 保证是纯背景）：

```
masterpiece, best quality, very aesthetic, absurdres, no humans, scenery,
<场景>, <时间/天气>, <镜头/光效>, detailed background, anime screencap, visual novel background
```

例：`… no humans, scenery, school rooftop, chain-link fence, water tower, sunset, orange sky, clouds, lens flare, wide shot, detailed background …`

常用 tag：

- 场景：`classroom / school hallway / school rooftop / clubroom / library / shrine / shopping district / cafe / beach / bedroom / train station / park`
- 时间天气：`afternoon / sunset / dusk / night / starry sky / rain / snow`
- 光效：`sunlight through windows, lens flare, bloom, god rays, rim light, backlighting, dust motes`
- 构图：`wide shot, from above, depth of field, blurry background, windows`

要一次出一批（比如同一场景多条候选），把 `EmptyLatentImage` 的 `batch_size` 改大即可；竖构图背景把宽高改成 832×1216（`LatentUpscale` 也跟着改成 1248×1824 或不放大）。12GB 显存上二段放大明显更慢，选中 `LatentUpscale` + `KSampler (Hires)` 按 **Ctrl+B** 旁路即可只用 1216×832 出图。

## 3. 9 向人物设定素材

两种产出形式，按用途挑：

**a) 单图 3×3 设定表 —— `anime_character_sheet.json`**

一张图里给出 9 格视角（正面全身 / 正面半身 / 侧面 / 背面 / 各 3/4 向），人物一致性最好，适合角色定稿、给美术当参考图、给下游立绘或 3D 外包对形状。改 `Prompt (Character Sheet)` 里的角色 tags（`1girl, solo, silver hair, long hair, blue eyes, school uniform …`，男性角色改 `1boy`）后 Queue，输出在 `output/anime/character_sheet/`。

**b) 分向单图 ×9 —— `anime_character_9views.json`**

一次出 9 张独立图片：8 个方向的全身图 + 1 张正面半身特写。9 个采样器共用 `Int (Seed)` 的同一个 seed 和同一份潜空间噪声，只换视角提示词 —— 所以 9 张之间人物最一致，出来的 PNG 可以直接当立绘素材或拿去训练角色 LoRA。输出在 `output/anime/character/1_front_full_*.png` 等。

用法上有两个关键点：

1. **角色描述只改一处**：`String (角色描述)` 节点（`1girl, solo, silver hair, …` 换成你的角色），它通过 `Concatenate Text` 拼到 9 个视角提示词前面。想微调某个视角，再改对应的 `String (视角 N)` 节点。
2. **换角色改 seed**：改 `Int (Seed)` 的值，9 张会一起换；把它的 `control_after_generate` 设成 `randomize`，每次 Queue 整组重新随机，方便刷角色形象。

注意：9 张共用 seed **不等于像素级同一张脸**（模型对不同视角的响应本来就有差异）。要更强一致性：步数提到 30+、CFG 6–7，多抽几组挑一套；或者先按 [video-reference.md](video-reference.md) 里「多视角人物一致性」那一节的思路定一张参考图，再挂 IPAdapter。SDXL 对精确 45° 角的控制有限，正面 / 侧面 / 背面最稳，3/4 向可能要重抽，严格角度请加 ControlNet (OpenPose)。

## 4. 底模与许可（能商用）

| 底模 | 许可 | 特点 |
|---|---|---|
| Illustrious XL v2.0（默认） | CreativeML OpenRAIL-M | Danbooru tag 遵循度最好，人物设定 / 立绘稳 |
| Animagine XL 4.0（可选） | CreativeML OpenRAIL++-M | 插画质感、光影、场景更好看 |

两者的许可**都允许商用**（含 galgame 素材、二次发表），要求是随附许可副本、保留出处声明，并遵守 OpenRAIL 的使用限制条款；生成内容的责任在使用者。权重来源（魔搭均有同名仓库，下载脚本默认走魔搭）：[OnomaAIResearch/Illustrious-XL-v2.0](https://modelscope.cn/models/OnomaAIResearch/Illustrious-XL-v2.0)、[cagliostrolab/animagine-xl-4.0](https://modelscope.cn/models/cagliostrolab/animagine-xl-4.0)。

想加风格 / 画师 LoRA：把 `.safetensors` 放进 `models/loras/`，在 WebUI 里拖一个 `Load LoRA` 节点插在 `Load Checkpoint` 和 `KSampler` 之间（`model` / `clip` 各接一条线），再刷新节点列表选文件即可。

> 也可以让 Agent 出图：这些工作流就是普通 ComfyUI 工作流，接上容器的 artokun MCP 后，Agent 能直接改提示词与尺寸并批量跑（见 [mcp.md](mcp.md)）。
