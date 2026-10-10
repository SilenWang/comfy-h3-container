#!/usr/bin/env bash
# 下载 SeedVR2 3B 放大/修复模型（视频高清化用），约 4GB。
#
# 来源（可用 MODELS_SOURCE 切换，默认 modelscope）：
#   - ModelScope（魔搭，国内快）: Comfy-Org/SeedVR2
#   - HuggingFace:               Comfy-Org/SeedVR2
#
# 用途：工作流里「HD Upscale (SeedVR2 3B)」那一段（把低清出片放大并复原细节）。
# 只有 diffusion 模型 + 对应的 VAE 两个文件，节点是 ComfyUI 0.39+ 内置的
# comfy_extras/nodes_seedvr.py，不需要额外自定义节点。
set -euo pipefail

# 下载源：modelscope（默认，魔搭）/ hf（HuggingFace）。可用 MODELS_SOURCE=... 覆盖。
SOURCE="${MODELS_SOURCE:-modelscope}"
case "$SOURCE" in
  modelscope|ms)
    BASE="https://modelscope.cn/models/Comfy-Org/SeedVR2/resolve/master"
    ;;
  hf|huggingface)
    BASE="https://huggingface.co/Comfy-Org/SeedVR2/resolve/main"
    ;;
  *)
    echo "未知的 MODELS_SOURCE：$SOURCE（可选：modelscope | hf）" >&2
    exit 2
    ;;
esac
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# 模型目录：默认仓库内 ./models；可用 MODELS_DIR 指向外部目录（与 compose 一致）。
MODELS="${MODELS_DIR:-$HERE/models}"
[[ "$MODELS" == /* ]] || MODELS="$HERE/$MODELS"

mkdir -p "$MODELS"/{diffusion_models,vae}

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

# 1. SeedVR2 3B 主模型（int8 + convrot 量化，3.46GB）
dl "$BASE/diffusion_models/seedvr2_3b_int8_convrot.safetensors" \
   "$MODELS/diffusion_models/seedvr2_3b_int8_convrot.safetensors"

# 2. SeedVR2 配套 VAE（0.50GB，与主模型成对使用）
dl "$BASE/vae/seedvr2_ema_vae_fp16.safetensors" \
   "$MODELS/vae/seedvr2_ema_vae_fp16.safetensors"

echo
echo "===== ALL DONE ====="
du -sh "$MODELS/diffusion_models/seedvr2_3b_int8_convrot.safetensors" \
       "$MODELS/vae/seedvr2_ema_vae_fp16.safetensors"
