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
  if [ -s "$dest" ]; then
    echo "SKIP (exists): $dest"
    return
  fi
  echo "=== downloading $dest ==="
  curl -fL --retry 3 -C - -o "$dest" "$url"
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
