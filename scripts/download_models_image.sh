#!/usr/bin/env bash
# 下载二次元插画（galgame 素材）用的 SDXL 动漫底模（单文件 checkpoints），约 6.9GB/个。
# 覆盖两类素材：场景图（背景）与 9 向人物设定素材（人物），对应工作流
#   workflows/anime_scene_t2i.json       场景图（含二段放大）
#   workflows/anime_character_sheet.json 9 向人物设定表（单图 3×3）
#   workflows/anime_character_9views.json 9 向人物分向单图（同 seed 出 9 张）
#
# 来源（可用 MODELS_SOURCE 切换，默认 modelscope）：
#   - ModelScope（魔搭，国内快）: OnomaAIResearch/Illustrious-XL-v2.0
#                                cagliostrolab/animagine-xl-4.0
#   - HuggingFace:               同名仓库
#
# 模型集（可用 IMAGE_MODELS 选择，默认 illustrious）：
#   illustrious  Illustrious XL v2.0（6.94GB，默认；Danbooru tag 遵循度最好）
#   animagine    Animagine XL 4.0（6.94GB；插画质感 / 光影更强）
#   all          上面两个都下（约 13.9GB）
set -euo pipefail

# 下载源：modelscope（默认，魔搭）/ hf（HuggingFace）。可用 MODELS_SOURCE=... 覆盖。
SOURCE="${MODELS_SOURCE:-modelscope}"
case "$SOURCE" in
  modelscope|ms)
    BASE_ILXL="https://modelscope.cn/models/OnomaAIResearch/Illustrious-XL-v2.0/resolve/master"
    BASE_ANIMA="https://modelscope.cn/models/cagliostrolab/animagine-xl-4.0/resolve/master"
    ;;
  hf|huggingface)
    BASE_ILXL="https://huggingface.co/OnomaAIResearch/Illustrious-XL-v2.0/resolve/main"
    BASE_ANIMA="https://huggingface.co/cagliostrolab/animagine-xl-4.0/resolve/main"
    ;;
  *)
    echo "未知的 MODELS_SOURCE：$SOURCE（可选：modelscope | hf）" >&2
    exit 2
    ;;
esac

IMAGE_MODELS="${IMAGE_MODELS:-illustrious}"
case "$IMAGE_MODELS" in
  illustrious|illustrious-xl|default) DO_ILXL=1; DO_ANIMA=0 ;;
  animagine|animagine-xl)             DO_ILXL=0; DO_ANIMA=1 ;;
  all)                                DO_ILXL=1; DO_ANIMA=1 ;;
  *)
    echo "未知的 IMAGE_MODELS：$IMAGE_MODELS（可选：illustrious | animagine | all）" >&2
    exit 2
    ;;
esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# 模型目录：默认仓库内 ./models；可用 MODELS_DIR 指向外部目录（与 compose 一致）。
# 相对路径按仓库根目录解析。
MODELS="${MODELS_DIR:-$HERE/models}"
[[ "$MODELS" == /* ]] || MODELS="$HERE/$MODELS"

mkdir -p "$MODELS/checkpoints"

# 远端文件大小：优先 HEAD 的 content-length（HuggingFace 可直接拿到）；
# ModelScope 的 HEAD 不返回长度，改用 Range 请求的 content-range（bytes 0-0/TOTAL）。
remote_size() {
  local url="$1" len
  len="$(curl -fsIL --http1.1 --retry 5 --retry-all-errors "$url" 2>/dev/null \
    | tr 'A-Z' 'a-z' | awk '/^content-length:/{v=$2} END{gsub(/[^0-9]/,"",v); print v}')"
  if [ -z "$len" ]; then
    len="$(curl -fsL --http1.1 --retry 5 --retry-all-errors -r 0-0 -o /dev/null -D - "$url" 2>/dev/null \
      | tr 'A-Z' 'a-z' | awk '/^content-range:/{n=split($0,a,"/"); v=a[n]; gsub(/[^0-9]/,"",v); print v}')"
  fi
  echo "$len"
}

dl() {
  local url="$1" dest="$2"
  # 远端文件大小（跟随 302 到最后 CDN）
  local expected
  expected="$(remote_size "$url")"

  if [ -s "$dest" ]; then
    local have
    have="$(stat -c %s "$dest")"
    if [ -n "$expected" ] && [ "$have" -eq "$expected" ]; then
      echo "SKIP (complete): $dest"
      return
    fi
    echo "RESUME: $dest ($have/${expected:-?} bytes)"
  fi

  echo "=== downloading $dest ==="
  # --http1.1：到 hf.co CDN 的 HTTP/2 连接不稳定，强制 1.1 实测稳定。
  # -C -：断点续传；--retry*：掉线自动重试并接着下。
  curl -fL --http1.1 \
    --retry 100 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --speed-limit 1048576 --speed-time 60 \
    -C - -o "$dest" "$url"
}

# 1. Illustrious XL v2.0（SDXL 动漫底模，6.94GB）— 默认；tag 遵循度好，人物设定 / 立绘
if [ "$DO_ILXL" = 1 ]; then
  dl "$BASE_ILXL/Illustrious-XL-v2.0.safetensors" \
     "$MODELS/checkpoints/illustrious-xl-v2.0.safetensors"
fi

# 2. Animagine XL 4.0（SDXL 动漫底模，6.94GB）— 可选；插画质感 / 光影 / 场景
if [ "$DO_ANIMA" = 1 ]; then
  dl "$BASE_ANIMA/animagine-xl-4.0.safetensors" \
     "$MODELS/checkpoints/animagine-xl-4.0.safetensors"
fi

echo
echo "===== ALL DONE ====="
du -sh "$MODELS"/*/
echo
echo "在 WebUI 里打开 workflows/anime_scene_t2i.json / anime_character_sheet.json / anime_character_9views.json 即可出图。"
