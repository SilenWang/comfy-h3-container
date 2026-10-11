#!/usr/bin/env bash
# 打印 artokun comfyui-mcp 的 AI 客户端配置片段（Claude Code / Claude Desktop / Cursor）。
#
#   ./scripts/mcp_client_config.sh               # artokun comfyui-mcp · 容器内托管服务（默认）
#   ./scripts/mcp_client_config.sh artokun       # 同上，显式指定
#
# 容器内只跑第三方 artokun/comfyui-mcp（能让 Agent 直接搭建 / 编辑工作流）：
#   随容器由 supervisord 托管，容器内以 Streamable HTTP 暴露（宿主端口见 compose，
#   默认 0.0.0.0:9100，同机其他容器 / 局域网可达），日志随容器日志。
#   远程客户端连 URL + Bearer token；同机其他容器别用 127.0.0.1（那是容器自己的
#   loopback），要用宿主 IP，或加 --add-host host.docker.internal:host-gateway。
#
# 官方 Comfy MCP Local（Comfy-Org/comfy-mcp，stdio）已彻底移除：镜像内不安装，
# 也不再提供宿主侧备选（它每次调用都要客户端 `docker exec -i <容器> comfy-mcp`
# 现起进程，配置繁琐、使用不便）。
set -euo pipefail

MODE="${1:-artokun}"
# COMFYUI_MCP_PORT_HOST 允许写成 "127.0.0.1:9100"（只绑宿主回环），取末段端口号。
MCP_PORT="${MCP_HTTP_PORT:-${COMFYUI_MCP_PORT_HOST:-9100}}"
MCP_PORT="${MCP_PORT##*:}"
TOKEN="${COMFYUI_MCP_HTTP_TOKEN:-comfy-h3-mcp}"

# 对外地址：优先 MCP_HTTP_PUBLIC_HOST，否则取本机第一个非回环 IPv4。
public_host() {
  if [[ -n "${MCP_HTTP_PUBLIC_HOST:-}" ]]; then
    echo "$MCP_HTTP_PUBLIC_HOST"
    return
  fi
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)"
  echo "${ip:-127.0.0.1}"
}

case "$MODE" in
  artokun)
    ENDPOINT="http://$(public_host):${MCP_PORT}/mcp"
    echo "# ── artokun comfyui-mcp · 容器内托管服务（Streamable HTTP）─────────"
    echo "# 随容器启动（supervisord 托管），无需额外起进程；宿主端口见 docker-compose.yml"
    echo "# （默认 0.0.0.0:9100 → 容器内 19100，同机其他容器 / 局域网可访问）。"
    echo "# 端点：${ENDPOINT}"
    echo "# 鉴权：请求头 Authorization: Bearer <token> 或 X-API-Key: <token>"
    echo "# 日志：与 comfyui / caddy 一起进容器日志（pixi run logs）"
    echo "# 同机其他容器：不能用 127.0.0.1（那是容器自己的 loopback），用宿主 IP，"
    echo "#   或在那个容器上 --add-host host.docker.internal:host-gateway 后用"
    echo "#   http://host.docker.internal:${MCP_PORT}/mcp。"
    echo
    echo "## Claude Code —— 一条命令注册："
    echo "claude mcp add --transport http comfyui ${ENDPOINT} \\"
    echo "  --header \"Authorization: Bearer ${TOKEN}\""
    echo
    echo "## Claude Desktop / Cursor —— 写入 claude_desktop_config.json 或 ~/.cursor/mcp.json："
    echo '{'
    echo '  "mcpServers": {'
    echo '    "comfyui": {'
    echo '      "type": "http",'
    echo "      \"url\": \"${ENDPOINT}\","
    echo '      "headers": {'
    echo "        \"Authorization\": \"Bearer ${TOKEN}\""
    echo '      }'
    echo '    }'
    echo '  }'
    echo '}'
    ;;

  *)
    echo "用法：$0 [artokun]（默认 artokun）" >&2
    exit 2
    ;;
esac
