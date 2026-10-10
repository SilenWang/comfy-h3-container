#!/usr/bin/env bash
# 后台下载 MiniMax H3 模型。首次下载很慢（实测 hf CDN 约 3MB/s），
# 远超一次性前台命令能跑完的时间，所以放到后台并保留可断点续传的日志。
#
#   ./scripts/download_models_bg.sh          # 基础模型（约 43GB），默认
#   ./scripts/download_models_bg.sh extra    # 参考/控制模型（约 25GB）
#   ./scripts/download_models_bg.sh image    # 二次元插画底模（约 6.9GB）
#
#   pixi run models-status             # 查看基础模型下载进度
#   pixi run models-extra-status       # 查看参考/控制模型下载进度
#   pixi run models-image-status       # 查看二次元插画底模下载进度
#   pixi run models-logs               # 跟踪基础模型下载日志
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
mkdir -p "$BUILD_DIR"

# 模型集：base（默认）或 extra。各自独立的脚本 / 日志 / PID。
case "${1:-base}" in
  base)
    SCRIPT="scripts/download_models.sh"
    LOG="$BUILD_DIR/models.log"
    PIDF="$BUILD_DIR/models.pid"
    STATUS_CMD="pixi run models-status"
    ;;
  extra)
    SCRIPT="scripts/download_models_extra.sh"
    LOG="$BUILD_DIR/models_extra.log"
    PIDF="$BUILD_DIR/models_extra.pid"
    STATUS_CMD="pixi run models-extra-status"
    ;;
  image)
    SCRIPT="scripts/download_models_image.sh"
    LOG="$BUILD_DIR/models_image.log"
    PIDF="$BUILD_DIR/models_image.pid"
    STATUS_CMD="pixi run models-image-status"
    ;;
  *)
    echo "未知的模型集：${1}（可选：base | extra | image）" >&2
    exit 2
    ;;
esac

if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "模型下载已在进行中（PID $(cat "$PIDF")）。"
  echo "查看进度：$STATUS_CMD"
  exit 0
fi

: > "$LOG"
cd "$ROOT"
setsid nohup bash "$SCRIPT" >> "$LOG" 2>&1 </dev/null &
disown 2>/dev/null || true
echo $! > "$PIDF"

echo "已后台启动模型下载（PID $(cat "$PIDF")）。"
echo "  日志：tail -f $LOG"
echo "  状态：$STATUS_CMD"
echo "下载脚本支持断点续传，中断后重跑会接着下。"
