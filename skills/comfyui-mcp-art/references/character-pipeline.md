# 角色：截图 → 提取 + 补完 → 定妆 → 9 向设定表

全部在 `qwen_image_edit_reference.json`（第 1、2 步）和 `qwen_image_edit_multiangle.json`（第 3 步）上做，不改工作流文件本身，只换输入图、指令、种子和输出前缀。

## 第 1 步：提取 + 补完（mask 分支打开）

源截图通常带姓名条、字幕、平台水印，角色也被这些 UI 压住一部分。这一步要一次把 UI 去掉、把被压住的身体补回来，其余像素不动。

1. `upload_image` 传两张图：
   - **图 1** = 源截图
   - **图 2** = **同一个角色的另一张完整截图**（视频里同一角色有成百上千帧，挑一张没被 UI 挡住的）
2. 给图 1 画 mask：`MaskEditor` 里把姓名条、字幕、水印涂白保存（写进 PNG 的 alpha 通道）。
3. 把 `Grow Mask`（expand 16）和 `Set Latent Noise Mask` 的 **Bypass 取消**。
4. 指令：

```text
去掉画面中的姓名条、字幕与平台水印，把被它们遮挡的人物身体补完整
（长袍下摆、裤子、鞋），线条、上色与画风与周围保持一致；
没有被遮挡的部分一个像素都不要改
```

5. 出图后先 `get_image` `action:"view"` 看一眼：只剩 mask 区域变了才算对。

要点：

- mask 面积越小越稳，只涂 UI 真正压住的地方；大片空洞会变成「合理推测」。
- 没有图 2 时模型会把空白原样保留——这是最常见的「补不上」。
- 判断 mask 生效：输出与输入完全一致 = mask 全黑或还在 Bypass。

## 第 2 步：定妆（mask 保持 Bypass）

目标是一张白底全身立绘，作为这个角色之后所有出图的唯一基准。

1. **图 1** = 第 1 步的结果；**图 2** = 同一部作品的任意一帧（只用来锚定画风）。
2. mask 分支保持 Bypass（开着就只会改 mask 内）。
3. 指令：

```text
以图 1 的角色为准：保留脸型、发型、瞳色、服装与姿势，
去掉背景换成纯白色，构图收成一张完整的全身立绘，线条与上色保持一致
```

4. 定妆图定稿后归档（建议按 `角色名_定妆.png` 命名），后续一律复用。

## 第 3 步：9 向设定表（`qwen_image_edit_multiangle.json`）

1. **图 1** = 定妆图；`图 2` 不用。
2. 只换机位指令，其它词与种子不动，跑 9 次：

```text
<sks> front view eye-level shot close-up
<sks> front view eye-level shot medium shot
<sks> front-right quarter view eye-level shot medium shot
<sks> right side view eye-level shot medium shot
<sks> back-right quarter view eye-level shot medium shot
<sks> back view eye-level shot medium shot
<sks> back-left quarter view eye-level shot medium shot
<sks> left side view eye-level shot medium shot
<sks> front-left quarter view eye-level shot medium shot
```

3. 9 张拼成 3×3 就是设定表（容器内可用 `ffmpeg -i "img%d.png" -vf tile=3x3` 或 hosting 侧拼图工具）。

要点：

- `medium shot` 实测出的是全身；要半身 / 特写先用 `close-up` 试一张再批量，避免 9 张构图不一。
- 机位词表共 96 个（`方位 8 × 仰俯 4 × 距离 3`），都贴在工作流的 `Note` 节点里。
- 多角度 LoRA 与 Lightning LoRA 叠在 Q3_K_S GGUF 上实测可跑，但属 experimental；出问题先降 LoRA 权重确认底座。

## 变体：表情差分（同一角色换表情）

- **图 1** = 定妆图；**图 2** = 同角色的**脸部裁剪**（只留表情信息）。
- 指令：`把图 1 角色的表情改成图 2 的表情，脸型、发型、瞳色、服装、姿势、构图与上色完全保持不变`
- 图 2 用整张截图会把她的背景、姓名条、台词一起带进来；要严格保构图就再叠 mask，只重绘脸部。

## 实测参考（RTX 3060 12GB，`--lowvram`）

| 步骤 | 单张耗时 |
|---|---|
| 提取 + 补完（mask） | 74–92 秒 |
| 定妆（全图编辑） | 76–91 秒 |
| 多机位（LoRA ×2） | 59–74 秒 |

输出分辨率由 `FluxKontextImageScale` 决定：1920×1080 的截图出来是 1392×752。
