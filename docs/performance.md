# 实测性能（RTX 3060 12GB）

| 配置 | 参数 | 耗时 | 说明 |
|---|---|---|---|
| 官方 8 步（未优化） | 512×288 / 4.46s | ~600s | 首次含 37GB 模型加载 |
| Turbo 4 步 + EasyCache + `--lowvram` | 512×288 / 4.46s | ~136s | 历史实测基线（此配置含 EasyCache，非当前自带 workflow） |
| **Turbo 4 步 + SageAttention + 文本编码器卸载 + `--lowvram`** | 608×352 / 2.33s | ~79s | 当前自带 workflow 默认配置，RTX 3060 12GB 实测（含模型加载）；SageAttention v2.2.0 由镜像构建期源码编译 |

更高分辨率（1344×768 原生画布 / 5s）参考社区实测约 7 分钟/段（Turbo 4 步）。

> 注意：`SageAttention` 只在 Ampere/Ada 及以后有收益（**RTX 30/40 系约 1.3–2×，Blackwell 较小**）；`H3EvictTextEncoder` 在 `--gpu-only` 模式下是 no-op。若 SageAttention 构建失败，把 `PathchSageAttentionKJ` 切到 `auto`（V1 Triton）或 `disabled` 即可无损回退；既有容器缺失时用 `pixi run fix-sage-attn` 现场补装（见 [troubleshooting.md](troubleshooting.md)）。

**未实测部分**：本文表格只覆盖视频链路。二次元生图（SDXL）与 Qwen-Image-Edit 修图的耗时本仓库没有 12GB 显卡上的实测数据，相关预期见 [image-anime.md](image-anime.md) 与 [image-edit.md](image-edit.md#4-12gb-显存上的预期与调参)。
