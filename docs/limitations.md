# 已知限制

1. 12GB 显存为「能跑但慢」的降级配置：权重（~37GB）无法全部驻留显存，推理时 CPU offload，速度受 PCIe 带宽限制
2. v4-600 Turbo LoRA 在 **4 步 + 大幅快速运动**场景偶有 motion-smear，遇到可改用 6-8 步（仍快于官方 20 步）
3. 完整 H3 系统（H3-Context-IR / 2K 再生）为云端 API，未开源；本方案为本地 H3-Base（768p 档）
4. 模型权重遵循 MiniMax H3 社区许可（注意地区限制：排除美 / 欧 / 英 / 韩）
5. PyPI 的 `sageattention` 只有 V1（Triton），不含 KJ 节点默认模式所需的 2.x CUDA 算子，故镜像构建期从源码编译官方 SageAttention **v2.2.0**（用 codeload tarball 拉源码，ai-dock 自带 nvcc，目标 arch 8.0/8.6，耗时数分钟），并先装 PyPI V1 兜底、编译后校验 import，避免「构建成功却漏装」。万一构建失败，把 `PathchSageAttentionKJ` 的模式改为 `auto`（V1）或 `disabled` 即可无损回退；既有容器可 `pixi run fix-sage-attn` 现场补装
6. 自带 workflow **不再内置 EasyCache**：4 步配置下其收益有限且后段可能起颗粒。需要时自行叠加默认参数的 `EasyCache`，且不要与其它缓存节点（如 Spectrum）叠在同一模型分支上
7. 内置工作流的视频解码用 `VAEDecodeTiled`（分块解码）：显存占用显著低于整段解码，且**画质逐像素一致**（同种子 A/B 实测 PSNR=inf / SSIM=1.0）。但 12GB 卡上限制时长的**真正瓶颈在采样阶段**：720p（1280×736）实测 **5 秒**可稳定出片，10 秒以上采样 / 解码均易 OOM；要更长请降到 0.4MP / 0.2MP，或换 16GB+ 显存的卡
8. R2V / 动作控制 / 多帧参考需额外约 25GB 模型（`pixi run models extra`），且 R2V 用的是独立的 `ref2va` 权重（与 T2V/I2V 的 `fl2va` 不通用）；三者需要 ComfyUI ≥ 0.35.0（本镜像构建时拉最新 master，满足）
9. R2V 的 4 步 Turbo LoRA 会削弱参考约束：人物一致性要求高时请跑 20–25 步（不是 4 步）；`ref_image_size=max` 更准但更慢
10. Fun ControlNet 依赖 SDPose 姿态提取，长视频 / 多人场景会增加预处理时间，控制强度与步数需按片段调
11. artokun/comfyui-mcp 是第三方实现（limited maintenance），工具面与官方 comfy-cli **不通用**；它由容器内 supervisord 托管，宿主端口默认绑所有接口（`0.0.0.0:9100`，同机其他容器 / 局域网可达），务必先把 `COMFYUI_MCP_HTTP_TOKEN` 改强；只想宿主机本机用可在 `.env` 里设 `COMFYUI_MCP_PORT_HOST=127.0.0.1:9100`（详见 [mcp.md](mcp.md)）
12. 二次元生图用的是 SDXL 底模（Illustrious XL v2.0 / Animagine XL 4.0，各约 6.9GB）：12GB 显存跑 1024 档没问题，但 [performance.md](performance.md) 的数字**只覆盖视频链路**，生图耗时未在本仓库实测；二段放大（hires）在 12GB 上明显更慢，可 Ctrl+B 旁路
13. SDXL 对精确 45° 视角控制有限：正面 / 侧面 / 背面最稳，3/4 向常需重抽，严格角度要靠 ControlNet (OpenPose)；`anime_character_9views` 里 9 张共用 seed 也不等于像素级同一张脸，一致性要求高时请提高步数 / CFG 并多抽几组挑选
14. 二次元底模许可：Illustrious XL v2.0 = CreativeML OpenRAIL-M，Animagine XL 4.0 = OpenRAIL++-M，**允许商用**（含 galgame 素材）但须随附许可副本、保留出处声明并遵守 OpenRAIL 使用限制条款；生成内容的责任在使用者
15. Qwen 修图链路（`workflows/qwen_image_edit_gguf*.json`）**需要重建镜像**：它依赖 ComfyUI-GGUF 节点（`Unet Loader (GGUF)` / `CLIPLoader (GGUF)`），旧镜像打开这两个工作流会报缺节点；工作流还用到 `TextEncodeQwenImageEditPlus` / `CFGNorm` / `FluxKontextImageScale`（本镜像构建时拉最新 master，满足）
16. Qwen 修图走 GGUF 量化，属**有损压缩**：默认 Q3_K_S（9.2GB）省显存，细节与图中文字偶尔会糊；要求高时换 `QWEN_EDIT_QUANT=Q4_K_S`（12.4GB，更慢、更吃内存）
17. Qwen 修图在 12GB 卡上的**耗时本仓库未实测**（链路、节点接线、量化档大小按官方 2511 模板 + ComfyUI 源码核对过）；20B 模型首次加载 9.2GB 主模型 + 4.7GB 文本编码器本身就慢，批量出素材请用 4 步 Lightning 档
18. Qwen 修图的文本编码器走 GGUF 时，`text_encoders/` 里必须有匹配的 mmproj（视觉塔）：下载脚本已把上游 `mmproj-F16.gguf` 重命名成 `Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf`。手动改文件名 / 换编码器量化档后如果日志出现 `Can't find mmproj file ... Qwen-Image-Edit will be broken!`，就是这条规则没满足（参考图会被忽略）
19. Lightning LoRA 叠在 GGUF 量化主模型上的效果**本仓库未实测**（ComfyUI-GGUF 对 LoRA 的支持官方标注为 experimental）：若日志报 LoRA 相关错误或画面异常，把 `4 步加速 LoRA` 节点的 `strength_model` 设 0，并把 KSampler 改回 `steps=20, cfg=4.0`（质量档参数），流程仍可跑
20. Qwen 修图的许可：Qwen-Image-Edit-2511、unsloth 的 GGUF 量化、lightx2v 的 Lightning LoRA、Qwen2.5-VL-7B 文本编码器**均为 Apache-2.0，允许商用**（含游戏素材），须随附许可副本并遵守其条款；生成内容责任在使用者
