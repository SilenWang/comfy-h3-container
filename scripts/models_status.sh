#!/usr/bin/env bash
# 查看后台模型下载（scripts/download_models_bg.sh）的状态、进度与日志尾部。
#
#   ./scripts/models_status.sh          # 基础模型（默认）
#   ./scripts/models_status.sh extra    # 参考/控制模型
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-base}" in
  base)
    LOG="$ROOT/.build/models.log"
    PIDF="$ROOT/.build/models.pid"
    LABEL="基础模型"
    ;;
  extra)
    LOG="$ROOT/.build/models_extra.log"
    PIDF="$ROOT/.build/models_extra.pid"
    LABEL="参考/控制模型"
    ;;
  *)
    echo "未知的模型集：${1}（可选：base | extra）" >&2
    exit 2
    ;;
esac

# 与 compose / download_models.sh 一致的模型目录（默认 ./models，可 MODELS_DIR 覆盖）
MODELS="${MODELS_DIR:-$ROOT/models}"
[[ "$MODELS" == /* ]] || MODELS="$ROOT/$MODELS"

if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "状态：RUNNING（$LABEL，PID $(cat "$PIDF")）"
else
  echo "状态：未在运行（$LABEL）"
fi

echo "--- 模型目录：$MODELS ---"
shopt -s nullglob
for f in "$MODELS"/*/*.safetensors; do
  printf '%10s  %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")"
done
shopt -u nullglob

if [[ -f "$LOG" ]]; then
  echo "--- $(basename "$LOG") 末尾 ---"
  tail -n 15 "$LOG"
else
  echo "（还没有日志，先运行 pixi run models-bg 或 pixi run models-extra-bg）"
fi
