#!/usr/bin/env bash
# 构建 / 续建 ComfyUI + H3 镜像。
#
# 为什么不用直接 `docker compose build`：
#   整镜像首次构建要拉 torch cu126、ComfyUI 依赖、Copilot 依赖，远超一次性
#   前台命令能跑完的时间。前台阻塞会拖住调用方（Agent 运行会在空闲/总时长
#   上限处被强制停止），但 Docker 已完成的分层会写进 BuildKit 缓存，
#   所以“后台启动 + 反复重跑”可以断点续建，重跑只会补没缓存的那几步。
#
#   ./scripts/build_image.sh          # 后台启动构建（已在跑则直接返回）
#   pixi run build-logs               # 跟踪日志
#   pixi run build-status             # 查看是否还在跑
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
LOG="$BUILD_DIR/build.log"
PIDF="$BUILD_DIR/build.pid"
mkdir -p "$BUILD_DIR"

if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "构建已在进行中（PID $(cat "$PIDF")）。"
  echo "查看进度：tail -f $LOG"
  exit 0
fi

: > "$LOG"
cd "$ROOT"
# setsid + nohup + stdin/stdout/stderr 全部脱离：调用方（Agent 运行）结束
# 也不会收到 SIGHUP，且不会因继承管道而挂住调用方。
setsid nohup bash -c \
  'docker compose build --progress=plain >> "'"$LOG"'" 2>&1; echo "EXIT=$?" >> "'"$LOG"'"' \
  </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
echo $! > "$PIDF"

echo "已启动后台构建（PID $(cat "$PIDF")）。"
echo "  日志：tail -f $LOG"
echo "  状态：pixi run build-status"
echo "说明：进程若被环境回收，BuildKit 缓存仍保留；重跑本脚本会自动续建。"
