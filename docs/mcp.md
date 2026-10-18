# AI 辅助：用 MCP 驱动 ComfyUI（本地 / 远程）

镜像内**只内置一套 MCP**：第三方的 [artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp) —— 由容器内 supervisord 托管、随容器启动、以 Streamable HTTP 暴露，客户端连一个 `URL + token` 即可，强于**让 Agent 直接搭建 / 编辑 / 校验工作流**。

[官方 Comfy MCP Local](https://github.com/Comfy-Org/comfy-mcp)（stdio，客户端每次都要 `docker exec -i comfyui-h3 comfy-mcp` 现起进程）**已彻底移除**：镜像内不再安装 `comfy-cli` / `comfy-mcp`，仓库也不再提供宿主侧备选（它用起来不方便、客户端配置繁琐），容器里只留第三方这一套。

## artokun/comfyui-mcp — 容器内托管服务（Agent 搭 / 改工作流 + 统一日志）

第三方 [artokun/comfyui-mcp](https://github.com/artokun/comfyui-mcp)（npm 包 `comfyui-mcp`）能让 Agent **帮你预配置 / 编辑工作流**：它能 `create_workflow`（从模板或从零建节点 / 连线 / 设参）、`modify`（增删改连）、`validate`（运行前校验）、`get_workflow` / `save_workflow`（读 / 存工作流库），还带模型家族 skills（含 **MiniMax H3**）。

**它以容器内服务运行，由 supervisord 托管、随容器一起启动**（不需要宿主另起进程）：

- 容器内以 **Streamable HTTP** 监听 `0.0.0.0:19100`，`docker-compose.yml` 映射到宿主 `0.0.0.0:9100`（不写 IP 即绑所有接口，**同机其他容器与局域网都能访问**）。
- 直连同容器 ComfyUI 的 `127.0.0.1:18188`，绕过 8188 上的 caddy。
- 日志写 `/var/log/supervisor/comfyui-mcp.log`；ai-dock 的 `logtail` 会把该目录所有日志汇总到容器 stdout，因此 **comfyui / caddy / comfyui-mcp 的日志在 `docker compose logs` 里都能同时看到**。

客户端配置（`pixi run mcp-config` 可随时打印）：

```jsonc
{
  "mcpServers": {
    "comfyui": {
      "type": "http",
      "url": "http://<宿主机IP>:9100/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

```bash
claude mcp add --transport http comfyui http://<宿主机IP>:9100/mcp \
  --header "Authorization: Bearer <token>"
```

### 谁能连、用什么地址

端口映射绑在**宿主**上，而容器各有独立网络命名空间 —— **容器内的 `127.0.0.1:9100` 是它自己的 loopback，连不到宿主的 9100**（同机其他容器也一样）。按调用方所在位置选地址：

| 调用方 | 端点 | 说明 |
|---|---|---|
| 宿主机本机 | `http://127.0.0.1:9100/mcp` | Claude Code / Cursor 跑在宿主上时 |
| **同机其他容器** | `http://<宿主在该容器网络上的网关IP>:9100/mcp` | 默认 bridge 是 `172.17.0.1`；自定义网络用 `docker network inspect <网络名>` 看 `Gateway`。更省事：给该容器加 `--add-host host.docker.internal:host-gateway`，然后用 `host.docker.internal` |
| 局域网其他机器 | `http://<宿主机IP>:9100/mcp` | 需防火墙放行 9100 |
| 与 `comfyui-h3` 同一 docker 网络的容器 | `http://comfyui-h3:19100/mcp` | 走容器网络直连**容器内**端口，不经宿主端口映射，最直接（compose 默认网络名 `<项目名>_default`，`docker network ls` 可查） |

同机其他容器接入示例（`host-gateway` 需要 Docker ≥ 20.10）：

```bash
docker run --rm --add-host host.docker.internal:host-gateway <你的镜像> \
  curl -X POST http://host.docker.internal:9100/mcp \
    -H 'Authorization: Bearer <token>' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

客户端配置里把 `url` 换成上表对应那一行即可：

```jsonc
{
  "mcpServers": {
    "comfyui": {
      "type": "http",
      "url": "http://host.docker.internal:9100/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

可配置项：

| 变量 | 默认 | 说明 |
|---|---|---|
| `COMFYUI_MCP_HTTP_TOKEN` | `comfy-h3-mcp` | 入站鉴权令牌（`Authorization: Bearer` / `X-API-Key`）。**端口默认对外开放，务必改成强随机值** |
| `COMFYUI_MCP_PORT_HOST` | `9100` | 宿主端口，绑所有接口（同机其他容器 + 局域网可达）。想收回成只允许宿主机本机：在 `.env` 里设 `COMFYUI_MCP_PORT_HOST=127.0.0.1:9100` |
| `COMFYUI_MCP_PORT_LOCAL` | `19100` | 容器内监听端口，与上面的宿主端口**联动**（`.env` 改一处即可，映射始终对齐） |

> ⚠️ **第三方 + 有限维护**：`artokun/comfyui-mcp` 是社区实现（MIT / Node ≥22），README 标注 limited maintenance，工具面与官方 comfy-cli **不通用**；H3 的 `MiniMaxH3TurboLoRA` / `PathchSageAttentionKJ` / `H3EvictTextEncoder` 这套专用链它也不认识，但能读容器里**实际安装**的 `/object_info`。最稳的用法是把仓库现成的 `workflows/*.json` 当模板喂给 Agent，让它在此基础上改参 / 接线。
>
> **安全**：端口默认绑宿主所有接口（`9100:19100`），同机容器与局域网都能连，而鉴权只有 Bearer token —— 默认值 `comfy-h3-mcp` 形同公开。**务必先在 `.env` 里设强随机值**（`openssl rand -hex 16`），且只部署在可信网络；跨不可信网络请套 TLS 反代或走 Tailscale / WireGuard。只想宿主机本机用：在 `.env` 里设 `COMFYUI_MCP_PORT_HOST=127.0.0.1:9100`。

## 查看 / 管理容器内服务（supervisor）

容器内由 supervisord 托管两个服务：`comfyui-mcp`（上文的 MCP，随容器启动）与
`comfyui-idle-free`（队列空闲后自动 `/free` 释放常驻模型与缓存，并丢弃模型文件页缓存，
见 [troubleshooting.md](troubleshooting.md#comfyui-跑完任务后内存--显存不释放后续任务卡死)）。

```bash
pixi run logs                                        # 跟踪容器日志（comfyui + caddy + comfyui-mcp 汇总）
pixi run mem-status                                  # cgroup 内存明细 + 显存 + idle-free 状态/日志
docker exec -it comfyui-h3 supervisorctl status
docker exec -it comfyui-h3 supervisorctl restart comfyui-mcp
docker exec -it comfyui-h3 tail -f /var/log/supervisor/comfyui-mcp.log
docker exec -it comfyui-h3 tail -f /var/log/supervisor/comfyui-idle-free.log   # 空闲释放守护
```

只想看某个服务：`docker exec comfyui-h3 tail -f /var/log/supervisor/caddy.log`。
