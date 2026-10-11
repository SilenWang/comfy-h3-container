# 视频生成（T2V / I2V）

## 1. 出片流程

1. WebUI 左侧 **Workflows** 选仓库自带模板：`minimax_h3_t2v_bund`（文生视频）/ `minimax_h3_i2v`（图生视频）/ `minimax_h3_r2v`（参考生视频）/ `minimax_h3_fun_controlnet_union`（动作控制）/ `minimax_h3_multiframe_reference`（多帧参考）；也可从 **Template Library → Video** 选官方 H3 模板。（二次元生图模板 `anime_scene_t2i` / `anime_character_sheet` / `anime_character_9views` 见 [image-anime.md](image-anime.md)；Qwen 修图模板 `qwen_image_edit_gguf_lightning` / `qwen_image_edit_gguf` 见 [image-edit.md](image-edit.md)）
2. 点 Queue 执行，等待输出（右侧 Video 面板可预览 / 下载）
3. 输出文件同时保存在宿主的 `./output/` 目录

后三种「参考」玩法需要额外模型（约 25GB，`pixi run models extra`），见 [video-reference.md](video-reference.md)。

## 2. 加速配置（自带 workflow 已调好）

仓库里的 `workflows/minimax_h3_t2v_bund.json` 与 `workflows/minimax_h3_i2v.json` 就是实测的 12GB 配置，容器启动即出现在 WebUI 的 Workflows 列表，已包含：

- `MiniMaxH3TurboLoRA`（`minimax_h3_turbo_v4_step600_ema.safetensors`，4 步）+ `MiniMaxH3TurboSampler`
- `PathchSageAttentionKJ`（ComfyUI-KJNodes）—— 注意力加速，模式默认 `sageattn_qk_int8_pv_fp16_cuda`、`allow_compile` 关闭。这是唯一「不改结果」的提速手段（Ampere/Ada 约 1.3–2×）；镜像构建期会从源码编译官方 SageAttention v2.2.0，若构建失败把模式切到 `auto`（V1 Triton）或 `disabled` 即可无损回退。既有容器若报 `No module named 'sageattention'`，直接 `pixi run fix-sage-attn` 现场补装即可，无需重建镜像（见 [troubleshooting.md](troubleshooting.md)）
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

## 3. 时长与分辨率

12GB 卡上限制时长的**真正瓶颈在采样阶段**：720p（1280×736）实测 **5 秒**可稳定出片，10 秒以上采样 / 解码均易 OOM；要更长请降到 0.4MP / 0.2MP，或换 16GB+ 显存的卡。内置工作流的视频解码用 `VAEDecodeTiled`（分块解码），显存占用显著低于整段解码，且画质逐像素一致。

更多限制见 [limitations.md](limitations.md)，功耗 / 耗时数据见 [performance.md](performance.md)。
