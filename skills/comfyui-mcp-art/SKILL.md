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

## 用 MCP 怎么调

连接配置用 `pixi run mcp-config` 打印（URL 与 token 由环境提供，**不要写进技能或脚本**）。工具名以服务端 `tools/list` 为准，这条流水线用到的是：

| 步骤 | 工具 | 说明 |
|---|---|---|
| 找模板 | `get_workflow` `action:"list"` / `"get"` | 仓库 `workflows/` 已挂进 ComfyUI 工作流库 |
| 读结构 | `get_workflow` `action:"analyze"` / `"strip"` | 先看懂节点再改；`strip` 能展开 bypass / 总线 |
| 传图 | `upload_image` | 图 1 / 图 2 传到 ComfyUI 的 `input/` |
| 校验 | `create_workflow` `action:"validate"` | 缺模型、断线、非法输出索引先在这里拦下 |
| 提交 | `enqueue_workflow` `action:"enqueue"` | **只收 API 格式**；仓库里是 UI 格式，用 `scripts/ui_to_api.js` 转 |
| 等结果 | `queue` `action:"status"`、`get_history` `action:"list"` | 失败用 `get_history` `action:"diagnose"` |
| 看图 | `get_image` `action:"view"` | **先看 1 张再批量**；身份或构图不对就别跑 9 张 |
| 释放显存 | `clear_vram` | 批量跑完释放；容器另有空闲自动释放 |

参数沿用工作流内置值：4 步 Lightning、CFG 1.0、euler + simple。RTX 3060 12GB 实测 **60–92 秒/张**（模型已缓存）。

## 用哪个工作流

| 工作流 | 用途 | 图 1 | 图 2 |
|---|---|---|---|
| `qwen_image_edit_reference.json` | 提取 + 补完、定妆、换表情 / 角度、场景换时段 | 基准图（要保住的东西） | 变量（缺失内容 / 表情 / 角度） |
| `qwen_image_edit_multiangle.json` | 9 向 / 多机位设定表 | 定妆图 | —（只写 `<sks> 方位 仰俯 距离`） |

`anime_character_9views.json` / `anime_character_sheet.json` 是纯文生图（只有 tag、没有参考图），出的 9 张是「同款但不是同一个角色」；需要同一角色时不要用它们。

## 流程

- 角色（截图 → 提取补完 → 定妆 → 9 向）：读 [references/character-pipeline.md](references/character-pipeline.md)
- 背景（截图 → 干净背景 → 多时段）：读 [references/background-pipeline.md](references/background-pipeline.md)

## 脚本

`scripts/ui_to_api.js` 把仓库里的 UI 版工作流 + 覆盖项转成 `enqueue_workflow` 能提交的 API JSON：

```bash
node scripts/ui_to_api.js ../../workflows/qwen_image_edit_reference.json overrides.json > prompt.json
```

- 覆盖项：`{"nodes":{"5":{"image":"shot.png"},"10":{"prompt":"…"}},"modes":{"17":0,"18":0}}`（`modes` 里 0 = 启用、4 = Bypass）
- 控件名默认从 `COMFY_HOST`（默认 `http://127.0.0.1:8188`）的 `/object_info` 取；离线时用 `--object-info-file <json>`
- 只输出 JSON，不发请求——提交仍然走 MCP

## 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| 输出和输入一模一样 | mask 没画上（全黑）或 mask 分支还在 Bypass | 重新涂白保存；确认 `Grow Mask`、`Set Latent Noise Mask` 已取消 Bypass |
| mask 内补出来还是空白 | 没有同角色参考，或指令没写「补什么」 | 图 2 放同角色完整图；指令点名要补的部位 |
| 人物变了 | 图 2 用了别的作品 / 别的角色 | 换同作品同角色的图 |
| 背景、字幕被带进结果 | 图 2 是整张截图 | 图 2 裁到只含脸 / 机位 |
| 输出尺寸和输入不一致 | `FluxKontextImageScale` 按固定尺寸表缩放 | 1920×1080 → 1392×752，后续抠像 / 缩放按输出尺寸对齐 |
| 提交报 required input missing | UI 版 JSON 的字段名与当前 `/object_info` 不一致（如 `reference_latents_method`） | 先 `create_workflow` `action:"validate"`，或按 `/object_info` 核对后再提交 |
| 多角度 LoRA 报错 / 画面糊 | GGUF 上叠 LoRA 属 experimental 路径 | 先把多角度 LoRA 的 `strength_model` 设 0 确认底座，再考虑换 Q4_K_S |
