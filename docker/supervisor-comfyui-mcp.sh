#!/bin/bash
# 容器内 artokun/comfyui-mcp 服务入口（由 supervisord 托管，随容器启动）。
#
# - 传输：Streamable HTTP，监听 0.0.0.0:${COMFYUI_MCP_PORT_LOCAL:-19100}
#         （由 docker-compose 映射到宿主，见 README）。
# - 目标 ComfyUI：同容器 127.0.0.1:${COMFYUI_PORT_LOCAL:-18188}（绕过 caddy）。
# - 日志走 stdout/stderr -> /var/log/supervisor/comfyui-mcp.log -> ai-dock logtail
#   -> `docker logs`，与 comfyui / caddy 的日志汇总在一起。
# - 鉴权：设 COMFYUI_MCP_HTTP_TOKEN 时启用（Authorization: Bearer / X-API-Key）；
#         未设则以无鉴权模式监听（artokun 需显式 --allow-unauthenticated-non-loopback），
#         仅应在受控网络里这样跑。
set -euo pipefail

# 确保能解析到镜像内安装的 Node / comfyui-mcp（console script 走 `#!/usr/bin/env node`）。
export PATH="/usr/local/bin:${PATH:-/usr/bin:/bin}"

MCP_BIN="/usr/local/bin/comfyui-mcp"
COMFY_URL="${COMFY_LOCAL_URL:-http://127.0.0.1:${COMFYUI_PORT_LOCAL:-18188}}"
MCP_PORT="${COMFYUI_MCP_PORT_LOCAL:-19100}"
TOKEN="${COMFYUI_MCP_HTTP_TOKEN:-}"

ARGS=(--comfyui-url "$COMFY_URL" --http --host 0.0.0.0 --port "$MCP_PORT")
if [[ -n "$TOKEN" ]]; then
  ARGS+=(--token "$TOKEN")
  printf "[comfyui-mcp] 鉴权已启用（Authorization: Bearer / X-API-Key）\n"
else
  ARGS+=(--allow-unauthenticated-non-loopback)
  printf "[comfyui-mcp] 警告：未设置 COMFYUI_MCP_HTTP_TOKEN，以无鉴权模式监听 0.0.0.0:%s\n" "$MCP_PORT"
fi

printf "[comfyui-mcp] 启动：%s %s\n" "$MCP_BIN" "${ARGS[*]}"
exec "$MCP_BIN" "${ARGS[@]}"
