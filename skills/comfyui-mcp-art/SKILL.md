---
name: comfyui-mcp-art
description: 用 comfy-h3 容器里的 ComfyUI（经 comfyui MCP 调用）把游戏/动画截图加工成二次元美术素材：角色提取与补完、白底定妆图、9 向设定表、背景多时段变体。只在「从截图产出 galgame 素材」时使用；不负责容器部署、模型下载或训练 LoRA。
---

# 用 ComfyUI MCP 从截图产出二次元素材

## 产出什么

- **角色**：截图 → 提取 + 补完 → 白底定妆图 → 9 向设定表
- **背景**：截图 → 干净背景 → 同地点多时段 / 天气变体

## 原则（先读，能省掉绝大多数返工）

1. **图 1 是「要保住的东西」，图 2 是「唯一允许变化的东西」。**
   图 1 = 角色 / 场景 / 构图；图 2 = 缺失内容 / 表情 / 角度 / 时段。指令里显式写「图 1 的 XX 保持不变」。

2. **图 2 带的是内容，不只是风格。**
   它会把背景、构图甚至主体一起带进来：拿别的作品的立绘当「画风模板」，输出人物会直接变成图 2 的角色。要保角色，图 2 必须是同一部作品、最好是同一角色的图；只想取表情 / 机位，就把图 2 裁到只剩那点信息。

3. **补全必须「mask + 同角色参考 + 写明补什么」。**
   只喂残图 + 一句「补全缺失部分」，模型会把空白 / 遮挡当成要保留的内容（实测）。mask 走 PNG 的 alpha 通道（MaskEditor 涂白保存），**mask 外的像素一个都不动**——这既是它的保证，也是判断 mask 有没有生效的标准。

两条推论：

- **画风只在作品内锁定**。这条链路不会把素材改成「别的作品的画风」；跨作品迁移画风要走风格 LoRA / USO，不在本技能范围。
- **一张定妆图全项目复用**。同一个角色的所有出图都从同一张定妆图出发；换角色就换定妆图，不要每次从截图重抽。

## MCP 调用骨架（实测跑通）

连接用 `pixi run mcp-config` 打印（URL 与 token 由环境提供，**不要写进技能**）。全部经 comfyui MCP 完成，不需要自建转换脚本、也不需要直接打 ComfyUI 的 HTTP API——`get_workflow` 的 `api` 格式就是可提交的 payload（bypass 已解析，`_meta.mode` 标注）。

```text
1. get_workflow    {action:"get", filename:"qwen_image_edit_reference.json"}
                   # 默认 format:"api"；返回末尾可能带 "Conversion warnings"（缺输入图/模型），先处理
2. upload_image    {action:"image", source_path:"<跑 MCP 那台机器上的绝对路径>"}
                   # → 返回 LoadImage 可用的文件名；已在 input/ 里的图可跳过
3. 改返回的 JSON    # 返回体是「JSON + 可选 Conversion warnings」两段，取前面的 JSON 解析
                   # 节点 id 与工作流里的数字一致：图 1=5、图 2=6、指令=10（多机位是 8）、KSampler.seed、SaveImage.filename_prefix
4. create_workflow {action:"validate", workflow:<patched>}
                   # 缺模型、断线、图片不在 input/ 都在这里报（会列出 valid options）
5. enqueue_workflow{action:"enqueue", workflow:<patched>}    # → {prompt_id}
                   # 注意：enqueue 不随机化 seed，要变的 seed 自己写
6. queue           {action:"status", prompt_id:"…"}          # → status_str: success | error
7. get_history     {action:"list", prompt_id:"…"}            # → 输出文件名，如 "sil382/xxx_00001_.png"
8. get_image       {action:"get", filename:"sil382/xxx_00001_.png"}
                   # 内联返回图片；同一台机器的 /tmp/comfyui-images/ 也会落一份
9. clear_vram      {}                                        # 批量跑完释放
```

| 目的 | 工具与关键参数 |
|---|---|
| 找模板 / 读结构 | `get_workflow` `{action:"list"}`、`{action:"analyze", filename}`、`{action:"strip", path}` |
| 传图 | `upload_image` `{action:"image", source_path}`；复用已有输出 `{action:"stage", filename}` |
| 校验 | `create_workflow` `{action:"validate", workflow}` |
| 单张提交 | `enqueue_workflow` `{action:"enqueue", workflow}` |
| 批量（9 机位） | `batch` `{action:"submit", workflows:[9 份 patch 后的 workflow]}` → `{action:"wait", batch_id}` → `{action:"output", batch_id}` |
| 等结果 | `queue` `{action:"status", prompt_id}`；失败诊断 `get_history` `{action:"diagnose", prompt_id}` |
| 看图 | `get_image` `{action:"get", filename}`（按文件名）/ `{action:"list_outputs"}`（浏览）/ `{action:"view", asset_id}`（按资产 id） |
| 存变体 | `save_workflow` `{action:"save", filename, workflow}` |

`batch` 的 `sweep` 是**按输入名**打到所有同名节点（如 `prompt` 会同时写进正向与负向节点），机位这类要精确改单个节点的场景用 `workflows` 数组，每份单独 patch。

参数沿用工作流内置值：4 步 Lightning、CFG 1.0、euler + simple。RTX 3060 12GB 实测 **59–92 秒/张**（模型已缓存）。

## 用哪个工作流

| 工作流 | 用途 | 图 1 | 图 2 |
|---|---|---|---|
| `qwen_image_edit_reference.json` | 提取 + 补完、定妆、换表情 / 角度、场景换时段 | 基准图（要保住的东西） | 变量（缺失内容 / 表情 / 角度） |
| `qwen_image_edit_multiangle.json` | 9 向 / 多机位设定表 | 定妆图 | —（只写 `<sks> 方位 仰俯 距离`） |

`anime_character_9views.json` / `anime_character_sheet.json` 是纯文生图（只有 tag、没有参考图），出的 9 张是「同款但不是同一个角色」；需要同一角色时不要用它们。

## 流程

- 角色（截图 → 提取补完 → 定妆 → 9 向）：读 [references/character-pipeline.md](references/character-pipeline.md)
- 背景（截图 → 干净背景 → 多时段）：读 [references/background-pipeline.md](references/background-pipeline.md)

## 验证记录

2026-10-17 用 MCP 实跑一遍：`get_workflow` 取 `qwen_image_edit_multiangle` 的 api 格式 → 改 `图 1` / 机位词 / seed / 输出前缀 → `create_workflow validate` 通过 → `enqueue_workflow`（59 秒完成）→ `get_history` 拿到输出文件名 → `get_image` 内联取回图片。同一天 `validate` 也正确拦下了 `LoadImage` 里不存在的图片名（列出可用文件）。角色/背景的指令与参数来自 SIL-382 的实跑对照。

## 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| 输出和输入一模一样 | mask 没画上（全黑）或 mask 分支还在 Bypass | 重新涂白保存；确认 `Grow Mask`、`Set Latent Noise Mask` 已取消 Bypass |
| mask 内补出来还是空白 | 没有同角色参考，或指令没写「补什么」 | 图 2 放同角色完整图；指令点名要补的部位 |
| 人物变了 | 图 2 用了别的作品 / 别的角色 | 换同作品同角色的图 |
| 背景、字幕被带进结果 | 图 2 是整张截图 | 图 2 裁到只含脸 / 机位 |
| 输出尺寸和输入不一致 | `FluxKontextImageScale` 按固定尺寸表缩放 | 1920×1080 → 1392×752，后续抠像 / 缩放按输出尺寸对齐 |
| 提交报 required input missing | 手写 API JSON 的字段名与当前 `/object_info` 不一致（如 `reference_latents_method`） | 别手写：从 `get_workflow` 的 api 格式改值，再 `create_workflow` `action:"validate"` |
| `validate` 报 `value_not_in_list` | 输入图不在 ComfyUI 的 `input/` | 先 `upload_image`（`action:"image"`），或 `action:"stage"` 复用已有输出 |
| `get_image` 报缺 `asset_id` | 用了 `action:"view"` | 按文件名取图是 `action:"get"` + `filename` |
| 多角度 LoRA 报错 / 画面糊 | GGUF 上叠 LoRA 属 experimental 路径 | 先把多角度 LoRA 的 `strength_model` 设 0 确认底座，再考虑换 Q4_K_S |
