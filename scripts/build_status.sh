#!/usr/bin/env bash
# 查看后台构建（scripts/build_image.sh）的状态与日志尾部。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$ROOT/.build/build.log"
PIDF="$ROOT/.build/build.pid"

if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "状态：RUNNING（PID $(cat "$PIDF")）"
else
  echo "状态：未在运行"
fi

if [[ -f "$LOG" ]]; then
  echo "--- build.log 末尾 ---"
  tail -n 25 "$LOG"
else
  echo "（还没有构建日志，先运行 pixi run build）"
fi
