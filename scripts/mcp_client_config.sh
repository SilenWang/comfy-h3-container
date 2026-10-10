#!/usr/bin/env bash
# 打印 Comfy MCP 的 AI 客户端配置片段（Claude Code / Claude Desktop / Cursor）。
#
#   ./scripts/mcp_client_config.sh               # 官方 comfy-mcp · 容器模式（stdio，推荐）
#   ./scripts/mcp_client_config.sh host          # 官方 comfy-mcp · 宿主模式（stdio）
#   ./scripts/mcp_client_config.sh artokun       # artokun comfyui-mcp · 本地 stdio（可搭/改工作流）
#   ./scripts/mcp_client_config.sh artokun-http  # artokun comfyui-mcp · 远程 Streamable HTTP
#
# 官方 comfy-mcp（comfy-cli 引擎，偏执行 / 模板 / 自省）：
#   容器模式：跑在 comfyui-h3 容器内，经 `docker exec -i` 调起，直连容器内
#             ComfyUI（127.0.0.1:18188），绕过 caddy 反代，与 WEB_ENABLE_AUTH 无关。
#   宿主模式：用当前 pixi 环境里的 comfy-mcp 连 `COMFYUI_URL`（需先关认证或填 401）。
#
# artokun/comfyui-mcp（第三方，能让 Agent 直接搭建 / 编辑工作流 + 原生远程 HTTP）：
#   本地 stdio：客户端拉起 `pixi run mcp-artokun`（经 COMFYUI_URL 驱动容器内 ComfyUI）。
#   远程 HTTP：先 `pixi run mcp-artokun-http` 起服务，再让客户端连 URL。
set -euo pipefail

MODE="${1:-docker}"
CONTAINER="${COMFY_CONTAINER_NAME:-comfyui-h3}"
HOST_URL="${COMFYUI_URL:-http://127.0.0.1:8188}"
MCP_PORT="${MCP_HTTP_PORT:-9100}"
TOKEN="${COMFYUI_MCP_HTTP_TOKEN:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  docker)
    echo "# ── 官方 comfy-mcp · 容器模式（stdio，推荐）───────────────────────"
    echo "# 前置：容器已启动（pixi run up），且宿主机有 docker CLI。"
    echo
    echo "## Claude Code —— 一条命令注册："
    echo "claude mcp add comfy-mcp -- docker exec -i ${CONTAINER} comfy-mcp"
    echo
    echo "## Claude Desktop / Cursor —— 写入 claude_desktop_config.json 或 ~/.cursor/mcp.json："
    echo '{'
    echo '  "mcpServers": {'
    echo '    "comfy-mcp": {'
    echo '      "command": "docker",'
    echo "      \"args\": [\"exec\", \"-i\", \"${CONTAINER}\", \"comfy-mcp\"]"
    echo '    }'
    echo '  }'
    echo '}'
    ;;

  host)
    COMFY_BIN="$(command -v comfy || true)"
    COMFY_MCP="$(command -v comfy-mcp || true)"
    if [[ -z "$COMFY_BIN" || -z "$COMFY_MCP" ]]; then
      echo "未在当前环境找到 comfy / comfy-mcp。" >&2
      echo "请先在本目录执行：pixi install && pixi run mcp-config host" >&2
      exit 1
    fi
    echo "# ── 官方 comfy-mcp · 宿主模式 ──────────────────────────────────────"
    echo "# 前置：comfy-cli 已有可用 workspace（comfy set-default <ComfyUI 目录>）。"
    echo "# 注意：宿主机上没有本机 ComfyUI，这里用 COMFYUI_URL 指向容器暴露的端口。"
    echo "#       若 .env 里 WEB_ENABLE_AUTH=true，请求会返回 401，请先关闭认证。"
    echo
    echo "## Claude Code —— 一条命令注册："
    echo "claude mcp add comfy-mcp \\"
    echo "  -e COMFY_BIN=${COMFY_BIN} \\"
    echo "  -e COMFYUI_URL=${HOST_URL} \\"
    echo "  -- ${COMFY_MCP}"
    echo
    echo "## Claude Desktop / Cursor —— 写入 claude_desktop_config.json 或 ~/.cursor/mcp.json："
    echo '{'
    echo '  "mcpServers": {'
    echo '    "comfy-mcp": {'
    echo "      \"command\": \"${COMFY_MCP}\","
    echo '      "env": {'
    echo "        \"COMFY_BIN\": \"${COMFY_BIN}\","
    echo "        \"COMFYUI_URL\": \"${HOST_URL}\""
    echo '      }'
    echo '    }'
    echo '  }'
    echo '}'
    ;;

  artokun)
    echo "# ── artokun comfyui-mcp · 本地 stdio ──────────────────────────────"
    echo "# 前置：pixi install（装 Node 22）；容器在跑（pixi run up）。"
    echo "# 说明：命令经 pixi 启动，保证用 pixi 管理的 Node；COMFYUI_URL 默认"
    echo "#       指向容器内 ComfyUI（宿主 localhost:18188），绕过 caddy 认证。"
    echo
    echo "## Claude Code —— 一条命令注册："
    echo "claude mcp add comfyui -- pixi run --manifest-path ${ROOT}/pixi.toml mcp-artokun"
    echo
    echo "## Claude Desktop / Cursor —— 写入 claude_desktop_config.json 或 ~/.cursor/mcp.json："
    echo '{'
    echo '  "mcpServers": {'
    echo '    "comfyui": {'
    echo '      "command": "pixi",'
    echo "      \"args\": [\"run\", \"--manifest-path\", \"${ROOT}/pixi.toml\", \"mcp-artokun\"]"
    echo '    }'
    echo '  }'
    echo '}'
    ;;

  artokun-http)
    BASE="http://$(public_host):${MCP_PORT}"
    ENDPOINT="${BASE}/mcp"
    echo "# ── artokun comfyui-mcp · 远程 Streamable HTTP ────────────────────"
    echo "# 前置：先起服务 —— MCP_HTTP_HOST=0.0.0.0 COMFYUI_MCP_HTTP_TOKEN=<随机串> \\"
    echo "#           pixi run mcp-artokun-http"
    echo "# 端点：${ENDPOINT}"
    echo "# 鉴权：请求头 Authorization: Bearer <token> 或 X-API-Key: <token>"
    echo "# 注意：绑非回环地址必须设 COMFYUI_MCP_HTTP_TOKEN（artokun 会拒绝无鉴权暴露）。"
    echo
    echo "## Claude Code —— 一条命令注册："
    echo "claude mcp add --transport http comfyui ${ENDPOINT} \\"
    echo "  --header \"Authorization: Bearer ${TOKEN:-<你的 token>}\""
    echo
    echo "## Claude Desktop / Cursor —— 写入 claude_desktop_config.json 或 ~/.cursor/mcp.json："
    echo '{'
    echo '  "mcpServers": {'
    echo '    "comfyui": {'
    echo '      "type": "http",'
    echo "      \"url\": \"${ENDPOINT}\","
    echo '      "headers": {'
    echo "        \"Authorization\": \"Bearer ${TOKEN:-<你的 token>}\""
    echo '      }'
    echo '    }'
    echo '  }'
    echo '}'
    ;;

  *)
    echo "用法：$0 [docker|host|artokun|artokun-http]" >&2
    exit 2
    ;;
esac
