#!/usr/bin/env bash
# 查看后台模型下载（scripts/download_models_bg.sh）的状态、进度与日志尾部。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$ROOT/.build/models.log"
PIDF="$ROOT/.build/models.pid"
# 与 compose / download_models.sh 一致的模型目录（默认 ./models，可 MODELS_DIR 覆盖）
MODELS="${MODELS_DIR:-$ROOT/models}"
[[ "$MODELS" == /* ]] || MODELS="$ROOT/$MODELS"

if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "状态：RUNNING（PID $(cat "$PIDF")）"
else
  echo "状态：未在运行"
fi

echo "--- 模型目录：$MODELS ---"
shopt -s nullglob
for f in "$MODELS"/*/*.safetensors; do
  printf '%10s  %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")"
done
shopt -u nullglob

if [[ -f "$LOG" ]]; then
  echo "--- models.log 末尾 ---"
  tail -n 15 "$LOG"
else
  echo "（还没有日志，先运行 pixi run models-bg）"
fi
