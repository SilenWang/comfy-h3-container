# 文档索引

本目录放项目的详细文档。仓库根目录的 [README](../README.md) 只保留容器介绍、内部包含的模型、使用方式、项目参考与许可这四类信息，其余细节都在这里。

| 文档 | 内容 |
|---|---|
| [deployment.md](deployment.md) | 部署与运维：目录准备、镜像构建（含后台续建）、启动 / 停止 / 日志、外部模型目录 |
| [models.md](models.md) | 模型清单、下载方式与开关、模型目录结构 |
| [configuration.md](configuration.md) | 环境变量配置说明、WebUI 认证 |
| [video.md](video.md) | 视频生成：T2V / I2V 工作流与加速配置（Turbo / SageAttention / 文本编码器卸载） |
| [video-reference.md](video-reference.md) | 更多参考方式：R2V 参考生视频、Fun ControlNet 动作控制、多帧参考 |
| [image-anime.md](image-anime.md) | 二次元插画生图：场景图与 9 向人物设定素材 |
| [image-edit.md](image-edit.md) | 修图：Qwen-Image-Edit 指令式改图（GGUF，12GB 显存可跑） |
| [mcp.md](mcp.md) | 用 MCP 驱动 ComfyUI（artokun/comfyui-mcp，容器内托管） |
| [performance.md](performance.md) | 实测性能（RTX 3060 12GB） |
| [limitations.md](limitations.md) | 已知限制 |
| [troubleshooting.md](troubleshooting.md) | 故障排查 |

## 常用命令速查

```bash
# 模型下载（唯一入口，类别作为参数；下载源固定魔搭 ModelScope）
pixi run models             # = base：基础视频模型，约 43GB
pixi run models extra       # 参考 / 控制模型（R2V + 动作控制），约 25GB
pixi run models image       # 二次元插画底模，约 6.9GB
pixi run models qwen-edit   # Qwen-Image-Edit 修图链路，约 16GB
pixi run models all         # 以上全部，约 91GB

# 镜像与容器
pixi run build && pixi run build-status   # 后台构建 + 续建（推荐）
pixi run up-build                         # 前台构建并启动（增量构建快）
pixi run up / down / restart / logs

# 其它
pixi run fix-sage-attn      # 现场补装 SageAttention（无需重建镜像）
pixi run mcp-config         # 打印 MCP 客户端配置片段
```

`pixi run models-extra` / `models-image` / `models-qwen-edit` 等价于上面的 `pixi run models <类别>`。
