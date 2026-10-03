#!/usr/bin/env bash
# 下载 MiniMax H3 量化模型（ComfyUI 官方版）与 Turbo 4 步 LoRA，约 43GB
# 来源：
#   - 量化模型: https://huggingface.co/Comfy-Org/MiniMax-H3
#   - Turbo LoRA: https://huggingface.co/larryvrh/MiniMax-H3-Turbo-Lora
set -euo pipefail

BASE_H3="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"
BASE_LORA="https://huggingface.co/larryvrh/MiniMax-H3-Turbo-Lora/resolve/main"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$HERE/models"

mkdir -p "$MODELS"/{diffusion_models,text_encoders,vae,loras}

dl() {
  local url="$1" dest="$2"
  # 远端文件大小（跟随 302 到最后 CDN，取最后一个 content-length）
  local expected
  expected="$(curl -fsIL --http1.1 --retry 5 --retry-all-errors "$url" 2>/dev/null \
    | awk 'BEGIN{IGNORECASE=1} /^content-length:/{v=$2} END{gsub(/[^0-9]/,"",v); print v}')"

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
