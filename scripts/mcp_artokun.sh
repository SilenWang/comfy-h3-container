#!/usr/bin/env bash
# 在宿主机上启动 artokun/comfyui-mcp（npm 包 `comfyui-mcp`），驱动容器内 ComfyUI。
#
# 为什么用它：官方 comfy-mcp 偏「执行 + 模板 + 自省」，而 artokun 这款能**让 Agent
# 直接搭建 / 编辑工作流**（create_workflow / edit_graph / validate / save_workflow），
# 并原生支持远程 Streamable HTTP —— 正好对应「用 Agent 预配置工作流」的需求。
#
# 用法：
#   ./scripts/mcp_artokun.sh stdio   # 本地 MCP 客户端（Claude Code / Cursor）拉起
#   ./scripts/mcp_artokun.sh http    # 远程 Streamable HTTP 服务（供其它机器连接）
#
# 环境变量：
#   COMFYUI_URL                 容器内 ComfyUI 地址（默认 http://127.0.0.1:18188）。
#                               18188 是容器内 ComfyUI 端口，compose 已映射到宿主
#                               localhost，**绕过 8188 上的 caddy 认证**，因此与
#                               WEB_ENABLE_AUTH 开关无关。也可改成 http://<host>:8188。
#   COMFYUI_MCP_VERSION         固定 npm 版本（默认 0.52.205）。
#   MCP_HTTP_HOST / MCP_HTTP_PORT  远程模式监听地址/端口（默认 127.0.0.1:9100）。
#   COMFYUI_MCP_HTTP_TOKEN      远程模式入站鉴权令牌（artokun 的 --token）。
#                               绑非回环地址时必须设置（artokun 会拒绝无鉴权的公网暴露）。
#   COMFYUI_PATH                可选：本机 ComfyUI 目录，供模型/输出等本地文件类工具。
#
# ⚠️ 安全：远程模式（MCP_HTTP_HOST != 127.0.0.1）务必设 COMFYUI_MCP_HTTP_TOKEN，
#    否则任何人都能通过该端口驱动你的 ComfyUI。跨公网请再叠加 TLS / 私有网络。
set -euo pipefail

MODE="${1:-stdio}"
PKG="${COMFYUI_MCP_PACKAGE:-comfyui-mcp}"
VERSION="${COMFYUI_MCP_VERSION:-0.52.205}"
COMFY_URL="${COMFYUI_URL:-http://127.0.0.1:18188}"

if ! command -v npx >/dev/null 2>&1; then
  echo "未找到 npx。请在本目录执行：pixi install（会装 pixi 管理的 Node 22）。" >&2
  exit 1
fi

COMMON=(npx -y "${PKG}@${VERSION}" --comfyui-url "$COMFY_URL")

case "$MODE" in
  stdio)
    echo "── artokun ComfyUI MCP（stdio）──────────────────────────────" >&2
    echo "目标 ComfyUI：$COMFY_URL" >&2
    echo "停止：Ctrl-C" >&2
    echo "─────────────────────────────────────────────────────────────" >&2
    exec "${COMMON[@]}"
    ;;
  http)
    HOST="${MCP_HTTP_HOST:-127.0.0.1}"
    PORT="${MCP_HTTP_PORT:-9100}"
    HTTP=(--http --host "$HOST" --port "$PORT")
    if [[ -n "${COMFYUI_MCP_HTTP_TOKEN:-}" ]]; then
      HTTP+=(--token "$COMFYUI_MCP_HTTP_TOKEN")
    elif [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" && "$HOST" != "::1" ]]; then
      if [[ "${COMFYUI_MCP_HTTP_ALLOW_UNAUTH:-}" == "1" ]]; then
        HTTP+=(--allow-unauthenticated-non-loopback)
      else
        echo "绑定非回环地址 $HOST 需要入站鉴权：" >&2
        echo "  请设 COMFYUI_MCP_HTTP_TOKEN=<随机串>（推荐），" >&2
        echo "  或显式 COMFYUI_MCP_HTTP_ALLOW_UNAUTH=1 以裸奔（不安全）。" >&2
        exit 2
      fi
    fi
    echo "── artokun ComfyUI MCP（远程 Streamable HTTP）───────────────" >&2
    echo "端点：  http://${HOST}:${PORT}/mcp" >&2
    echo "鉴权：  $([[ -n "${COMFYUI_MCP_HTTP_TOKEN:-}" ]] && echo 'Bearer / X-API-Key Token 已启用' || echo '未启用（仅回环）')" >&2
    echo "目标 ComfyUI：$COMFY_URL" >&2
    echo "停止：Ctrl-C" >&2
    echo "─────────────────────────────────────────────────────────────" >&2
    exec "${COMMON[@]}" "${HTTP[@]}"
    ;;
  *)
    echo "用法：$0 [stdio|http]" >&2
    exit 2
    ;;
esac
