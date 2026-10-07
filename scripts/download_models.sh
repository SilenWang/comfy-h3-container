#!/usr/bin/env bash
# 下载 MiniMax H3 量化模型（ComfyUI 官方版）与 Turbo 4 步 LoRA，约 43GB
# 来源（可用 MODELS_SOURCE 切换，默认 modelscope）：
#   - ModelScope（魔搭，国内快）: https://modelscope.cn/models/Comfy-Org/MiniMax-H3
#   - HuggingFace:               https://huggingface.co/Comfy-Org/MiniMax-H3
set -euo pipefail

# 下载源：modelscope（默认，魔搭）/ hf（HuggingFace）。可用 MODELS_SOURCE=... 覆盖。
SOURCE="${MODELS_SOURCE:-modelscope}"
case "$SOURCE" in
  modelscope|ms)
    BASE_H3="https://modelscope.cn/models/Comfy-Org/MiniMax-H3/resolve/master"
    BASE_LORA="https://modelscope.cn/models/larryvrh/MiniMax-H3-Turbo-Lora/resolve/master"
    ;;
  hf|huggingface)
    BASE_H3="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"
    BASE_LORA="https://huggingface.co/larryvrh/MiniMax-H3-Turbo-Lora/resolve/main"
    ;;
  *)
    echo "未知的 MODELS_SOURCE：$SOURCE（可选：modelscope | hf）" >&2
    exit 2
    ;;
esac
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# 模型目录：默认仓库内 ./models；可用 MODELS_DIR 指向外部目录（与 compose 一致）。
# 相对路径按仓库根目录解析。
MODELS="${MODELS_DIR:-$HERE/models}"
[[ "$MODELS" == /* ]] || MODELS="$HERE/$MODELS"

mkdir -p "$MODELS"/{diffusion_models,text_encoders,vae,loras}

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
  # --http1.1：到 hf.co CDN 的 HTTP/2 连接不稳定（常见 stream CANCEL / SSL 错误），
  #           强制 1.1 后实测稳定。
  # -C -：断点续传；--retry*：掉线自动重试并接着下。
  # --speed-limit/--speed-time：传输卡死（<1MB/s 持续 60s）时主动断开交给重试。
  curl -fL --http1.1 \
    --retry 100 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --speed-limit 1048576 --speed-time 60 \
    -C - -o "$dest" "$url"
}

# 1. 主模型（FL2VA，int8 剪枝，20.97GB）— T2V / I2V / 首尾帧
dl "$BASE_H3/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
   "$MODELS/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors"

# 2. 文本编码器（Qwen3-VL 32B，nvfp4-AWQ，15.69GB）
dl "$BASE_H3/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
   "$MODELS/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"

# 3. 视频 VAE（5.21GB）与音频 VAE（0.61GB）
dl "$BASE_H3/vae/minimax_h3_video_vae_fp16.safetensors" \
   "$MODELS/vae/minimax_h3_video_vae_fp16.safetensors"
dl "$BASE_H3/vae/minimax_h3_audio_vae_fp32.safetensors" \
   "$MODELS/vae/minimax_h3_audio_vae_fp32.safetensors"

# 4. 官方 8 步 Turbo LoRA（1.96GB，可选；速度/质量平衡）
dl "$BASE_H3/loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors" \
   "$MODELS/loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"

# 5. v4-600 Turbo LoRA（780MB，推荐：4 步 + EasyCache 实测最快）
dl "$BASE_LORA/minimax_h3_turbo_v4_step600_ema.safetensors" \
   "$MODELS/loras/minimax_h3_turbo_v4_step600_ema.safetensors"

echo
echo "===== ALL DONE ====="
du -sh "$MODELS"/*/
