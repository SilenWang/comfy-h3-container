#!/usr/bin/env bash
# 下载 Qwen-Image-Edit（阿里指令式修图 / 改图）链路权重 —— 走 GGUF 量化，12GB 显存可跑。
#
# 覆盖工作流：
#   workflows/qwen_image_edit_gguf.json            质量档（20 步 / cfg 4.0）
#   workflows/qwen_image_edit_gguf_lightning.json  4 步加速档（Lightning LoRA，批量出素材用）
#
# 为什么用 GGUF：Qwen-Image-Edit-2511 是 20B 模型，Comfy-Org 官方权重 fp8/int8 就有 20.5GB、
# bf16 40.9GB，12GB 显存装不下；GGUF Q3_K_S 只有 9.2GB，配合镜像默认的 --lowvram 与 CPU
# offload 才在 RTX 3060 12GB 上跑得动。
#
# 文本编码器（Qwen2.5-VL-7B）同样走 GGUF，并且**必须**在同一目录放一份 mmproj（视觉塔）：
# ComfyUI-GGUF 在加载 qwen2vl 文本编码器时，按「文件名包含编码器基名（去掉量化后缀）」的
# 规则在 text_encoders/ 里找 mmproj*.gguf，找不到就报
# "Qwen-Image-Edit will be broken"。上游 unsloth 的 mmproj 文件名叫 mmproj-F16.gguf（不含
# 模型名），所以脚本会把它落盘成 Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf 以满足该规则。
#
# 来源（可用 MODELS_SOURCE 切换，默认 modelscope）：
#   - ModelScope（魔搭，国内快）: unsloth/Qwen-Image-Edit-2511-GGUF
#                                unsloth/Qwen2.5-VL-7B-Instruct-GGUF
#                                Comfy-Org/Qwen-Image_ComfyUI（VAE / fp8 文本编码器）
#                                lightx2v/Qwen-Image-Edit-2511-Lightning（4 步 LoRA）
#   - HuggingFace:               同名仓库（resolve/main）
#
# 可选开关（都可与 pixi 任务组合使用）：
#   QWEN_EDIT_QUANT       主模型量化档，默认 Q3_K_S（9.2GB）。
#                         画质优先可换 Q4_K_S（12.4GB）/ Q4_0（11.9GB）/ Q5_K_M（15.0GB），
#                         更吃内存与 offload，12GB 卡上更慢。
#   QWEN_EDIT_TEXT_QUANT  文本编码器量化档，默认 Q4_K_M（4.7GB）。
#   QWEN_EDIT_TEXT_ENC    文本编码器形式：gguf（默认，4.7GB + 1.3GB mmproj）
#                         | fp8（9.4GB safetensors，原生 CLIPLoader 直接可用、免 mmproj）
#                         | both（两种都下，工作流里换节点即可对比）
#   QWEN_EDIT_LIGHTNING   是否下 4 步 Lightning LoRA（0.81GB），默认 1；设 0 跳过。
#
# 全部下齐约 16GB（默认 gguf 文本编码器 + Lightning LoRA）；只下质量档约 15GB。
set -euo pipefail

# 下载源：modelscope（默认，魔搭）/ hf（HuggingFace）。可用 MODELS_SOURCE=... 覆盖。
SOURCE="${MODELS_SOURCE:-modelscope}"
case "$SOURCE" in
  modelscope|ms)
    BASE="https://www.modelscope.cn/models"
    REV="resolve/master"
    ;;
  hf|huggingface)
    BASE="https://huggingface.co"
    REV="resolve/main"
    ;;
  *)
    echo "未知的 MODELS_SOURCE：$SOURCE（可选：modelscope | hf）" >&2
    exit 2
    ;;
esac

# <repo> <远端路径> -> 直链
url() { echo "$BASE/$1/$REV/$2"; }

# 量化档只允许字母数字下划线，避免拼出错误 URL / 路径
check_quant() {
  local value="$1" name="$2"
  if [[ -z "$value" || ! "$value" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "非法的 $name：$value（只允许字母 / 数字 / 下划线，例：Q3_K_S、Q4_K_S）" >&2
    exit 2
  fi
}

QUANT="${QWEN_EDIT_QUANT:-Q3_K_S}"
TEXT_QUANT="${QWEN_EDIT_TEXT_QUANT:-Q4_K_M}"
TEXT_ENC="${QWEN_EDIT_TEXT_ENC:-gguf}"
LIGHTNING="${QWEN_EDIT_LIGHTNING:-1}"

check_quant "$QUANT" QWEN_EDIT_QUANT
check_quant "$TEXT_QUANT" QWEN_EDIT_TEXT_QUANT

case "$TEXT_ENC" in
  gguf) DO_TEXT_GGUF=1; DO_TEXT_FP8=0 ;;
  fp8|safetensors) DO_TEXT_GGUF=0; DO_TEXT_FP8=1 ;;
  both) DO_TEXT_GGUF=1; DO_TEXT_FP8=1 ;;
  *)
    echo "未知的 QWEN_EDIT_TEXT_ENC：$TEXT_ENC（可选：gguf | fp8 | both）" >&2
    exit 2
    ;;
esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# 模型目录：默认仓库内 ./models；可用 MODELS_DIR 指向外部目录（与 compose 一致）。
# 相对路径按仓库根目录解析。
MODELS="${MODELS_DIR:-$HERE/models}"
[[ "$MODELS" == /* ]] || MODELS="$HERE/$MODELS"

mkdir -p "$MODELS/diffusion_models" "$MODELS/text_encoders" "$MODELS/vae" "$MODELS/loras"

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

# 1. 主模型（Qwen-Image-Edit-2511 GGUF，默认 Q3_K_S 9.2GB）
#    diffusion_models/ 已由 extra_model_paths.yaml 映射进容器，ComfyUI-GGUF 的
#    "Unet Loader (GGUF)" 直接能选到（unet_gguf 复用 diffusion_models 的搜索路径）。
MAIN_FILE="qwen-image-edit-2511-${QUANT}.gguf"
dl "$(url unsloth/Qwen-Image-Edit-2511-GGUF "$MAIN_FILE")" \
   "$MODELS/diffusion_models/$MAIN_FILE"

# 2. 文本编码器（Qwen2.5-VL-7B GGUF）+ mmproj（视觉塔，必需）
if [ "$DO_TEXT_GGUF" = 1 ]; then
  TEXT_FILE="Qwen2.5-VL-7B-Instruct-${TEXT_QUANT}.gguf"
  dl "$(url unsloth/Qwen2.5-VL-7B-Instruct-GGUF "$TEXT_FILE")" \
     "$MODELS/text_encoders/$TEXT_FILE"
  # 重命名成「基名 + mmproj」：ComfyUI-GGUF 用文件名匹配，原名 mmproj-F16.gguf 会匹配失败。
  dl "$(url unsloth/Qwen2.5-VL-7B-Instruct-GGUF mmproj-F16.gguf)" \
     "$MODELS/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf"
fi

# 3. 文本编码器 fp8 版（可选）：原生 CLIPLoader 直接可用，免 mmproj；9.4GB，显存压力更大
if [ "$DO_TEXT_FP8" = 1 ]; then
  dl "$(url Comfy-Org/Qwen-Image_ComfyUI split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors)" \
     "$MODELS/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
fi

# 4. VAE（0.25GB，主模型 / 文本编码器 / 解码共用）
dl "$(url Comfy-Org/Qwen-Image_ComfyUI split_files/vae/qwen_image_vae.safetensors)" \
   "$MODELS/vae/qwen_image_vae.safetensors"

# 5. Lightning 4 步 LoRA（0.81GB）：把 20 步压到 4 步，12GB 卡批量出素材必装
if [ "$LIGHTNING" = 1 ]; then
  dl "$(url lightx2v/Qwen-Image-Edit-2511-Lightning Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors)" \
     "$MODELS/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
fi

echo
echo "===== ALL DONE ====="
du -sh "$MODELS"/*/
echo
echo "在 WebUI 里打开 workflows/qwen_image_edit_gguf_lightning.json（4 步加速档）或"
echo "workflows/qwen_image_edit_gguf.json（20 步质量档），加载一张图 + 写一句中文指令即可修图。"
echo "若把 QWEN_EDIT_TEXT_ENC 设成 fp8/both，可在工作流里把 CLIPLoader (GGUF) 换成原生 CLIPLoader 并选 qwen_2.5_vl_7b_fp8_scaled.safetensors。"
