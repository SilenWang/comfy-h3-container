#!/usr/bin/env bash
# 把容器内的 stdio Comfy MCP（`comfy-mcp`）网桥成远程 HTTP，供 MCP 客户端连接。
#
# 背景：官方 comfy-mcp 是 stdio server，MCP 客户端必须把它当子进程拉起；
#       本脚本用 supergateway 在宿主侧起一个 HTTP 网关，网关再通过
#       `docker exec -i <容器> comfy-mcp` 拉起容器里的 stdio server，
#       于是任何支持远程传输的 MCP 客户端都能直接连 URL，无需 docker / pixi。
#
# 传输方式（MCP_HTTP_TRANSPORT）：
#   streamableHttp（默认）—— MCP 2025-03-26 起的现行标准，POST + 可选 SSE，端点 /mcp
#   sse                  —— 旧版 HTTP+SSE（2024-11-05），端点 /sse + POST /message
#
# 可用环境变量：
#   MCP_HTTP_TRANSPORT   streamableHttp | sse   （默认 streamableHttp）
#   MCP_HTTP_HOST        监听地址               （默认 0.0.0.0；仅本机用可设 127.0.0.1）
#   MCP_HTTP_PORT        监听端口               （默认 8765）
#   COMFY_CONTAINER_NAME 容器名                 （默认 comfyui-h3）
#   SUPERGATEWAY_VERSION supergateway 版本       （默认 4.1.0）
#
# ⚠️ 安全：supergateway 4.1.x 没有内置入站鉴权。绑 0.0.0.0 时任何能访问该端口的人
#    都能驱动本机 ComfyUI（跑工作流、读输出）。仅限可信局域网；要跨网络请放在
#    带 TLS + 鉴权的反向代理后，或走 Tailscale / WireGuard 等私有网络。
set -euo pipefail

TRANSPORT="${MCP_HTTP_TRANSPORT:-streamableHttp}"
PORT="${MCP_HTTP_PORT:-8765}"
HOST="${MCP_HTTP_HOST:-0.0.0.0}"
CONTAINER="${COMFY_CONTAINER_NAME:-comfyui-h3}"
SG_VERSION="${SUPERGATEWAY_VERSION:-4.1.0}"

if ! command -v docker >/dev/null 2>&1; then
  echo "未找到 docker，无法通过 docker exec 拉起容器内的 comfy-mcp。" >&2
  exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "容器 '$CONTAINER' 未在运行。先启动：pixi run up" >&2
  exit 1
fi

ARGS=(
  npx -y "supergateway@${SG_VERSION}"
  --stdio "docker exec -i ${CONTAINER} comfy-mcp"
  --host "$HOST" --port "$PORT"
  --logLevel info
  --healthEndpoint /healthz
)

case "$TRANSPORT" in
  streamableHttp|streamablehttp)
    ARGS+=(--outputTransport streamableHttp --streamableHttpPath /mcp)
    ENDPOINT="http://${HOST}:${PORT}/mcp"
    ;;
  sse)
    ARGS+=(--outputTransport sse --ssePath /sse --messagePath /message)
    ENDPOINT="http://${HOST}:${PORT}/sse"
    ;;
  *)
    echo "未知 MCP_HTTP_TRANSPORT：$TRANSPORT（应为 streamableHttp 或 sse）" >&2
    exit 2
    ;;
esac

echo "── 远程 MCP 网关 ─────────────────────────────────────────────"
echo "传输：  $TRANSPORT"
echo "端点：  $ENDPOINT"
echo "健康：  http://${HOST}:${PORT}/healthz"
echo "上游：  docker exec -i ${CONTAINER} comfy-mcp"
echo "停止：  Ctrl-C"
echo "⚠️  无内置鉴权，切勿在公网直接暴露该端口。"
echo "──────────────────────────────────────────────────────────────"
exec "${ARGS[@]}"
