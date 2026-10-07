#!/usr/bin/env bash
# 下载“更多参考方式”所需的 MiniMax H3 模型：参考生视频（R2V）与动作控制
# （Fun ControlNet Union / Pose），约 25GB。基础 T2V/I2V 模型见 download_models.sh。
#
# 来源（可用 MODELS_SOURCE 切换，默认 modelscope）：
#   - ModelScope（魔搭，国内快）: Comfy-Org/MiniMax-H3、Comfy-Org/SDPose
#   - HuggingFace:               Comfy-Org/MiniMax-H3、Comfy-Org/SDPose
#
# 说明：R2V / 多帧参考共用 ref2va 主模型；Fun ControlNet 在 ref2va 之上再挂一个
# 控制补丁（model_patches/），并用 SDPose 从驱动视频里提取姿态骨架。
set -euo pipefail

# 下载源：modelscope（默认，魔搭）/ hf（HuggingFace）。可用 MODELS_SOURCE=... 覆盖。
SOURCE="${MODELS_SOURCE:-modelscope}"
case "$SOURCE" in
  modelscope|ms)
    BASE_H3="https://modelscope.cn/models/Comfy-Org/MiniMax-H3/resolve/master"
    BASE_SDPOSE="https://modelscope.cn/models/Comfy-Org/SDPose/resolve/master"
    ;;
  hf|huggingface)
    BASE_H3="https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main"
    BASE_SDPOSE="https://huggingface.co/Comfy-Org/SDPose/resolve/main"
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

mkdir -p "$MODELS"/{diffusion_models,loras,model_patches,checkpoints}

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

# 1. 参考生视频主模型（ref2va，int8 剪枝，19.53GB）
#    R2V / 多帧参考 / Fun ControlNet 都基于它。
dl "$BASE_H3/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" \
   "$MODELS/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors"

# 2. Fun ControlNet Union 补丁（2.14GB）— Canny / Depth / HED / MLSD / Pose + 重绘
dl "$BASE_H3/model_patches/minimax_h3_fun_controlnet_union_pruned_int8_convrot.safetensors" \
   "$MODELS/model_patches/minimax_h3_fun_controlnet_union_pruned_int8_convrot.safetensors"

# 3. 参考 4 步 Turbo LoRA（1.82GB，可选；R2V 工作流的 Lightning LoRA）
dl "$BASE_H3/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" \
   "$MODELS/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"

# 4. SDPose 姿态提取（1.79GB）— Fun ControlNet 工作流里从视频提骨架
dl "$BASE_SDPOSE/checkpoints/sdpose_wholebody_fp16.safetensors" \
   "$MODELS/checkpoints/sdpose_wholebody_fp16.safetensors"

# 5. SDPose 人体检测器（0.12GB）
dl "$BASE_SDPOSE/diffusion_models/rt_detr_v4-x-hgnet_fp16.safetensors" \
   "$MODELS/diffusion_models/rt_detr_v4-x-hgnet_fp16.safetensors"

echo
echo "===== ALL DONE ====="
du -sh "$MODELS"/*/
