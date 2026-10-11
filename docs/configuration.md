# 配置说明

## WebUI 认证：是什么、能不能去掉

**不是 ComfyUI 自带的，ComfyUI 本体没有任何账号体系。** 认证来自基础镜像 [ai-dock/comfyui](https://github.com/ai-dock/comfyui) 内置的 **caddy 反向代理**（HTTP Basic Auth），它的设计目的是防止公网端口扫描器发现并滥用服务。所以：

- **能去掉**，官方支持一个环境变量开关：`WEB_ENABLE_AUTH=false`。
- 去掉后对本项目没有副作用：WebUI、REST API、容器内 MCP 全都正常工作。

请求链路上认证在哪一层：

```
宿主 :8188  ──►  容器内 caddy :8188  ──(可选的 Basic Auth)──►  容器内 ComfyUI :18188
                        ▲                                              ▲
                  浏览器访问走这里                        容器内 MCP / 脚本直连走这里
```

改法（已在 `.env.example` 里默认设好）：

```bash
# .env
WEB_ENABLE_AUTH=false
```

```bash
docker compose up -d      # 重建容器生效
```

想改回来：设回 `true`（或删掉该行）并设置 `WEB_PASSWORD`，再 `docker compose up -d`。

> ⚠️ **安全提醒**：关闭认证后，**任何能访问 8188 端口的人都能无密码使用 WebUI 和 API**。局域网内自用没问题，但如果这台机器有公网 IP / 端口转发，请不要关闭，或用防火墙限制来源网段。只想本机用（连局域网也不开放）可以把 `docker-compose.yml` 的端口改成 `"127.0.0.1:8188:8188"`。

## 环境变量

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `WEB_ENABLE_AUTH` | `true`（镜像默认）/ `false`（`.env.example`） | caddy Basic Auth 开关。`false` 免密码访问，局域网自用推荐 |
| `WEB_PASSWORD` | `comfy-h3`（镜像默认） | 仅在 `WEB_ENABLE_AUTH=true` 时生效（账号固定 `user`） |
| `COMFYUI_PORT_HOST` | `8188` | 对外端口（caddy 反向代理） |
| `COMFYUI_PORT_LOCAL` | `18188` | 容器内 ComfyUI 监听端口（**不可与 HOST 相同**，否则端口冲突） |
| `COMFYUI_ARGS` | `--listen 0.0.0.0 --lowvram` | ComfyUI 启动参数（`--lowvram` 为 12GB 显存关键优化） |
| `MODELS_DIR` | `./models` | 模型目录（宿主侧），挂载到容器 `/workspace/models`，下载脚本同样认这个变量，详见 [deployment.md](deployment.md#5-用外部模型目录避免每次重新下载) |
| `OUTPUT_DIR` | `./output` | 生成结果目录（宿主侧），挂载到容器 `/opt/ComfyUI/output` |
| `COMFY_LOCAL_URL` | `http://127.0.0.1:18188` | 容器内 artokun MCP 连 ComfyUI 的地址（供 MCP 使用） |
| `COMFYUI_MCP_HTTP_TOKEN` | `comfy-h3-mcp`（镜像默认） | artokun MCP 服务的入站鉴权令牌；对局域网 / 公网开放前务必改强，详见 [mcp.md](mcp.md) |
| `COMFYUI_MCP_PORT_HOST` | `9100` | artokun MCP 的宿主端口（绑所有接口；可写成 `127.0.0.1:9100` 收回成本机） |
| `COMFYUI_MCP_PORT_LOCAL` | `19100` | artokun MCP 的容器内监听端口（与宿主端口联动） |

`docker compose` 会自动读仓库根目录的 `.env`；改完 `.env` 需 `docker compose up -d` 重建容器才生效（`restart` 不会重读）。

模型下载相关的变量（`IMAGE_MODELS` / `QWEN_EDIT_*` / `MODELS_DIR`）见 [models.md](models.md#可选环境变量)。
