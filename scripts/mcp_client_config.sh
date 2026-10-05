#!/usr/bin/env bash
# 打印 Comfy MCP Local 的 AI 客户端配置片段（Claude Code / Claude Desktop / Cursor）。
#
#   ./scripts/mcp_client_config.sh          # 容器模式（推荐）
#   ./scripts/mcp_client_config.sh host     # 宿主模式
#
# 容器模式：MCP server 跑在 comfyui-h3 容器内，经 `docker exec -i` 调起，
#          直连容器内 ComfyUI（127.0.0.1:18188），绕过 caddy 反代，
#          因此与 WEB_ENABLE_AUTH 的开关无关，不需要任何认证配置。
# 宿主模式：用当前 pixi 环境里的 comfy-mcp 连 `COMFYUI_URL`。
#          需要 comfy-cli 已有可用 workspace，且宿主没有本机 ComfyUI；
#          若 WEB_ENABLE_AUTH=true，调用会撞上 401，需先关闭认证。
set -euo pipefail

MODE="${1:-docker}"
CONTAINER="${COMFY_CONTAINER_NAME:-comfyui-h3}"
HOST_URL="${COMFYUI_URL:-http://127.0.0.1:8188}"

if [[ "$MODE" == "docker" ]]; then
  echo "# ── 容器模式（推荐）────────────────────────────────────────────────"
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
  exit 0
fi

if [[ "$MODE" != "host" ]]; then
  echo "用法：$0 [docker|host]" >&2
  exit 2
fi

COMFY_BIN="$(command -v comfy || true)"
COMFY_MCP="$(command -v comfy-mcp || true)"
if [[ -z "$COMFY_BIN" || -z "$COMFY_MCP" ]]; then
  echo "未在当前环境找到 comfy / comfy-mcp。" >&2
  echo "请先在本目录执行：pixi install && pixi run mcp-config host" >&2
  exit 1
fi

echo "# ── 宿主模式 ───────────────────────────────────────────────────────"
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