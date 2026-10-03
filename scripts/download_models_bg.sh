#!/usr/bin/env bash
# 后台下载 MiniMax H3 模型（约 43GB）。首次下载很慢（实测 hf CDN 约 3MB/s），
# 远超一次性前台命令能跑完的时间，所以放到后台并保留可断点续传的日志。
#
#   ./scripts/download_models_bg.sh    # 后台启动（已在跑则直接返回）
#   pixi run models-status             # 查看进度
#   pixi run models-logs               # 跟踪日志
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
LOG="$BUILD_DIR/models.log"
PIDF="$BUILD_DIR/models.pid"
mkdir -p "$BUILD_DIR"

if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "模型下载已在进行中（PID $(cat "$PIDF")）。"
  echo "查看进度：pixi run models-status"
  exit 0
fi

: > "$LOG"
cd "$ROOT"
setsid nohup bash scripts/download_models.sh >> "$LOG" 2>&1 </dev/null &
disown 2>/dev/null || true
echo $! > "$PIDF"

echo "已后台启动模型下载（PID $(cat "$PIDF")）。"
echo "  日志：tail -f $LOG"
echo "  状态：pixi run models-status"
echo "下载脚本支持断点续传，中断后重跑会接着下。"
