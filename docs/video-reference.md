# 更多参考方式：R2V / 动作控制 / 多帧参考

除 T2V / I2V 外，H3 原生支持三种更强的「参考」玩法。仓库已附对应官方工作流，使用前先下额外模型（约 25GB）：

```bash
pixi run models-extra      # 参考 / 控制模型：ref2va 主模型 + 控制补丁 + R2V Turbo LoRA + SDPose
```

这几个模板需要 **ComfyUI ≥ 0.35.0**——本镜像构建时会拉最新 master，满足要求。

## 1. 多视角人物一致性：参考生视频（R2V）

`minimax_h3_r2v.json`，核心是 `MiniMax H3 Reference to Video` 节点。给同一个人的正面 / 侧面 / 背面等多张图，模型据此锁定长相，显著降低视频里脸部和服装的抖动漂移。

- 参考可以是图片、视频、音频的任意组合，上限 **9 张图 + 3 段视频 + 3 段音频**。
- 在 prompt 里按连接顺序用 `<Picture 1>`、`<Video 1>`、`<Audio 1>` 引用，并**显式分工**（哪张管长相、哪张管风格、哪段管动作 / 运镜 / 音色）——官方实测这样效果好很多。
- `ref_image_size`：`match`（缩到出图分辨率，快）；`max`（短边最高 2048，长相更准但更慢）。
- R2V 用的是 **ref2va** 主模型，与 T2V / I2V 的 `fl2va` 是两套权重（额外模型里已含）。
- 4 步 Turbo LoRA 会削弱参考约束：人物越要像，越应跑 **20 步（必要时 25 步）**。

## 2. 舞蹈 / 动作控制：Fun ControlNet Union

`minimax_h3_fun_controlnet_union.json`，核心是 `Apply MiniMax H3 Fun ControlNet` 节点，把一段**控制视频**作为运动模板。单个检查点同时支持 **Canny / Depth / HED / MLSD / Pose**，还能接 `mask` 做局部重绘。

- 工作流自带 **SDPose 子图**：直接喂一段舞蹈视频，它自动提取骨骼，输出复现舞者动作（示例输入即 `dancer_field_pose.mp4`）。也可自行预处理后直接接 `control_video`。
- `guidance_scale` 保持 1.0；只有画面明显偏离控制时才把补丁 `strength` 调大。
- 依赖 `model_patches/` 下的控制补丁与 `checkpoints/` 下的 SDPose，需 ComfyUI ≥ 0.35.0。
- 想「免姿态提取、直接迁移动作且保住人物身份」，可另试 Wan Animate 2（另一条管线，要另下模型，本仓库未内置）。

## 3. 时间轴锚点：多帧参考（Multiframe Reference）

`minimax_h3_multiframe_reference.json`，用 `MiniMaxH3AddGuide` 在**任意帧**锚定参考图 / 音频（不再局限于首尾帧）。例如在第 60 帧钉一张定妆图，强制视频经过该帧；或喂前 22 帧 + 音频让模型续写。

- 把 H3 节点的 `positive` 与 latent 接到 `MiniMaxH3AddGuide`，给 `image` / `audio` + `frame_idx`（负数从尾部数）；可串联多个节点锚多个帧。
- 它是**条件锚点**而非视频转视频：要改风格用 R2V，要重绘局部用 Fun ControlNet 的 mask。

> 这三个模板基于 Comfy-Org 官方模板，仅把视频 VAE 指向本仓库已下载的 `minimax_h3_video_vae_fp16.safetensors`，省去重复下载 int8 VAE。
