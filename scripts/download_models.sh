#!/usr/bin/env bash
# 模型下载（本仓库唯一的模型下载入口）：按类别下载对应模型。
# 下载源固定为魔搭 ModelScope（国内速度快、连接稳定），不使用 HuggingFace。
#
#   bash scripts/download_models.sh            # 等价于 base
#   bash scripts/download_models.sh base       # 基础视频模型（T2V / I2V / 首尾帧），约 43GB
#   bash scripts/download_models.sh extra      # 参考 / 控制模型（R2V + 动作控制），约 25GB
#   bash scripts/download_models.sh image      # 二次元插画底模（SDXL），约 6.9GB
#   bash scripts/download_models.sh qwen-edit  # Qwen-Image-Edit 修图链路（GGUF），约 16GB
#   bash scripts/download_models.sh all        # 上面全部，约 91GB
#
# 也可走 pixi：pixi run models [base|extra|image|qwen-edit|all]（等价于 pixi run models-extra 等）。
#
# 行为：
#   - 已下载完整（本地大小 == 远端大小）的文件直接 SKIP，不重复占流量；
#   - 下了一半的文件从断点续传（curl -C -），中断后重跑接着下。
#   - 下载量大（base 约 43GB、all 约 91GB），建议在 tmux / screen 里跑，或自行放后台：
#     nohup bash scripts/download_models.sh > models.log 2>&1 &
#
# 可选环境变量：
#   MODELS_DIR           模型目录，默认仓库内 ./models（与 docker-compose 的挂载一致）
#   IMAGE_MODELS         image 类别：illustrious（默认）| animagine | all
#   QWEN_EDIT_QUANT      qwen-edit 主模型量化档，默认 Q3_K_S
#   QWEN_EDIT_TEXT_QUANT qwen-edit 文本编码器量化档，默认 Q4_K_M
#   QWEN_EDIT_TEXT_ENC   qwen-edit 文本编码器形式：gguf（默认）| fp8 | both
#   QWEN_EDIT_LIGHTNING  是否下 4 步 Lightning LoRA，默认 1；设 0 跳过
set -euo pipefail

usage() {
  cat <<'EOF'
用法：bash scripts/download_models.sh [类别]

类别：
  base        基础视频模型（T2V / I2V / 首尾帧），约 43GB（默认）
  extra       参考 / 控制模型（R2V + 动作控制 + SDPose），约 25GB
  image       二次元插画底模（SDXL），约 6.9GB
  qwen-edit   Qwen-Image-Edit 修图链路（GGUF），约 16GB
  all         以上全部，约 91GB

可选环境变量：
  MODELS_DIR            模型目录，默认仓库内 ./models
  IMAGE_MODELS          image 类别：illustrious（默认）| animagine | all
  QWEN_EDIT_QUANT       qwen-edit 主模型量化档，默认 Q3_K_S
  QWEN_EDIT_TEXT_QUANT  qwen-edit 文本编码器量化档，默认 Q4_K_M
  QWEN_EDIT_TEXT_ENC    qwen-edit 文本编码器形式：gguf（默认）| fp8 | both
  QWEN_EDIT_LIGHTNING   是否下 4 步 Lightning LoRA，默认 1；设 0 跳过

下载源为魔搭 ModelScope；已下载完整的文件会跳过，中断后重跑从断点续传。
EOF
}

# 魔搭 ModelScope（唯一下载源）。
MS="https://modelscope.cn/models"
REV="resolve/master"
# <仓库> <仓库内路径> -> 直链
url() { echo "$MS/$1/$REV/$2"; }

# 模型目录：默认仓库内 ./models；可用 MODELS_DIR 指向外部目录（与 compose 一致）。
# 相对路径按仓库根目录解析。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS="${MODELS_DIR:-$HERE/models}"
[[ "$MODELS" == /* ]] || MODELS="$HERE/$MODELS"
mkdir -p "$MODELS"/{diffusion_models,text_encoders,vae,loras,model_patches,checkpoints}

# 远端文件大小：ModelScope 的 HEAD 不返回 content-length，改用 Range 请求的
# content-range（bytes 0-0/TOTAL）拿总大小。
remote_size() {
  local u="$1" len
  len="$(curl -fsIL --http1.1 --retry 5 --retry-all-errors "$u" 2>/dev/null \
    | tr 'A-Z' 'a-z' | awk '/^content-length:/{v=$2} END{gsub(/[^0-9]/,"",v); print v}')"
  if [ -z "$len" ]; then
    len="$(curl -fsL --http1.1 --retry 5 --retry-all-errors -r 0-0 -o /dev/null -D - "$u" 2>/dev/null \
      | tr 'A-Z' 'a-z' | awk '/^content-range:/{n=split($0,a,"/"); v=a[n]; gsub(/[^0-9]/,"",v); print v}')"
  fi
  echo "$len"
}

dl() {
  local u="$1" dest="$2" expected have
  expected="$(remote_size "$u")"

  # 已下载完整（大小与远端一致）则跳过，避免重复占流量；大小不符（下了一半）则续传。
  if [ -s "$dest" ]; then
    have="$(stat -c %s "$dest")"
    if [ -n "$expected" ] && [ "$have" -eq "$expected" ]; then
      echo "SKIP (complete): $dest"
      return
    fi
    echo "RESUME: $dest ($have/${expected:-?} bytes)"
  fi

  echo "=== downloading $dest ==="
  # --http1.1：CDN 上 HTTP/2 连接不稳定，强制 1.1 实测稳定。
  # -C -：断点续传；--retry*：掉线自动重试并接着下。
  # --speed-limit/--speed-time：传输卡死（<1MB/s 持续 60s）时主动断开交给重试。
  curl -fL --http1.1 \
    --retry 100 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --speed-limit 1048576 --speed-time 60 \
    -C - -o "$dest" "$u"
}

# ── base：基础视频模型（T2V / I2V / 首尾帧），约 43GB ─────────────────────
download_base() {
  local repo="Comfy-Org/MiniMax-H3"
  echo "### 基础视频模型（T2V / I2V，约 43GB）"
  # 1. 主模型（FL2VA，int8 剪枝，20.97GB）
  dl "$(url "$repo" diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors)" \
     "$MODELS/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors"
  # 2. 文本编码器（Qwen3-VL 32B，nvfp4-AWQ，15.69GB）
  dl "$(url "$repo" text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors)" \
     "$MODELS/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
  # 3. 视频 VAE（5.21GB）与音频 VAE（0.61GB）
  dl "$(url "$repo" vae/minimax_h3_video_vae_fp16.safetensors)" \
     "$MODELS/vae/minimax_h3_video_vae_fp16.safetensors"
  dl "$(url "$repo" vae/minimax_h3_audio_vae_fp32.safetensors)" \
     "$MODELS/vae/minimax_h3_audio_vae_fp32.safetensors"
  # 4. 官方 8 步 Turbo LoRA（1.96GB，可选；速度 / 质量平衡）
  dl "$(url "$repo" loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors)" \
     "$MODELS/loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"
  # 5. v4-600 Turbo LoRA（0.78GB）—— 自带工作流默认用这个，4 步出片
  dl "$(url larryvrh/MiniMax-H3-Turbo-Lora minimax_h3_turbo_v4_step600_ema.safetensors)" \
     "$MODELS/loras/minimax_h3_turbo_v4_step600_ema.safetensors"
}

# ── extra：参考 / 控制模型，约 25GB ──────────────────────────────────────
# R2V / 多帧参考共用 ref2va 主模型；Fun ControlNet 在 ref2va 之上再挂一个控制补丁
# （model_patches/），并用 SDPose 从驱动视频里提取姿态骨架。
download_extra() {
  echo "### 参考 / 控制模型（R2V + 动作控制，约 25GB）"
  # 1. 参考生视频主模型（ref2va，int8 剪枝，19.53GB）
  dl "$(url Comfy-Org/MiniMax-H3 diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors)" \
     "$MODELS/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors"
  # 2. Fun ControlNet Union 补丁（2.14GB）— Canny / Depth / HED / MLSD / Pose + 重绘
  dl "$(url Comfy-Org/MiniMax-H3 model_patches/minimax_h3_fun_controlnet_union_pruned_int8_convrot.safetensors)" \
     "$MODELS/model_patches/minimax_h3_fun_controlnet_union_pruned_int8_convrot.safetensors"
  # 3. 参考 4 步 Turbo LoRA（1.82GB，可选；R2V 工作流的 Lightning LoRA）
  dl "$(url Comfy-Org/MiniMax-H3 loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors)" \
     "$MODELS/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors"
  # 4. SDPose 姿态提取（1.79GB）+ 人体检测器（0.12GB）
  dl "$(url Comfy-Org/SDPose checkpoints/sdpose_wholebody_fp16.safetensors)" \
     "$MODELS/checkpoints/sdpose_wholebody_fp16.safetensors"
  dl "$(url Comfy-Org/SDPose diffusion_models/rt_detr_v4-x-hgnet_fp16.safetensors)" \
     "$MODELS/diffusion_models/rt_detr_v4-x-hgnet_fp16.safetensors"
}

# ── image：二次元插画（galgame 素材）底模，约 6.9GB/个 ────────────────────
# 对应工作流 workflows/anime_scene_t2i.json、anime_character_sheet.json、
# anime_character_9views.json。
download_image() {
  local image_models="${IMAGE_MODELS:-illustrious}" do_ilxl do_anima
  case "$image_models" in
    illustrious|illustrious-xl|default) do_ilxl=1; do_anima=0 ;;
    animagine|animagine-xl)             do_ilxl=0; do_anima=1 ;;
    all)                                do_ilxl=1; do_anima=1 ;;
    *)
      echo "未知的 IMAGE_MODELS：$image_models（可选：illustrious | animagine | all）" >&2
      exit 2
      ;;
  esac

  echo "### 二次元插画底模（IMAGE_MODELS=$image_models）"
  # Illustrious XL v2.0（6.94GB）— 默认；Danbooru tag 遵循度好，人物设定 / 立绘稳
  if [ "$do_ilxl" = 1 ]; then
    dl "$(url OnomaAIResearch/Illustrious-XL-v2.0 Illustrious-XL-v2.0.safetensors)" \
       "$MODELS/checkpoints/illustrious-xl-v2.0.safetensors"
  fi
  # Animagine XL 4.0（6.94GB）— 可选；插画质感 / 光影 / 场景更好看
  if [ "$do_anima" = 1 ]; then
    dl "$(url cagliostrolab/animagine-xl-4.0 animagine-xl-4.0.safetensors)" \
       "$MODELS/checkpoints/animagine-xl-4.0.safetensors"
  fi
}

# ── qwen-edit：Qwen-Image-Edit 修图链路（GGUF），约 16GB ──────────────────
# 为什么用 GGUF：Qwen-Image-Edit-2511 是 20B 模型，官方 fp8/int8 权重就有 20.5GB，
# 12GB 显存装不下；GGUF Q3_K_S 只有 9.2GB，配合镜像默认的 --lowvram + CPU offload
# 才能在 RTX 3060 12GB 上跑得动。
# 文本编码器（Qwen2.5-VL-7B）同样走 GGUF，且**必须**在同一目录放一份 mmproj（视觉塔）：
# ComfyUI-GGUF 按「文件名包含编码器基名（去掉量化后缀）」的规则找 mmproj*.gguf，找不到就报
# "Qwen-Image-Edit will be broken"（参考图被当成没有）。上游 unsloth 的文件名叫
# mmproj-F16.gguf（不含模型名），所以本脚本把它落盘成 Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf。
download_qwen_edit() {
  local quant="${QWEN_EDIT_QUANT:-Q3_K_S}"
  local text_quant="${QWEN_EDIT_TEXT_QUANT:-Q4_K_M}"
  local text_enc="${QWEN_EDIT_TEXT_ENC:-gguf}"
  local lightning="${QWEN_EDIT_LIGHTNING:-1}"
  local do_text_gguf do_text_fp8 value

  # 量化档只允许字母数字下划线，避免拼出错误 URL / 路径
  for value in "$quant" "$text_quant"; do
    if [[ ! "$value" =~ ^[A-Za-z0-9_]+$ ]]; then
      echo "非法的量化档：$value（只允许字母 / 数字 / 下划线，例：Q3_K_S、Q4_K_S）" >&2
      exit 2
    fi
  done

  case "$text_enc" in
    gguf)            do_text_gguf=1; do_text_fp8=0 ;;
    fp8|safetensors) do_text_gguf=0; do_text_fp8=1 ;;
    both)            do_text_gguf=1; do_text_fp8=1 ;;
    *)
      echo "未知的 QWEN_EDIT_TEXT_ENC：$text_enc（可选：gguf | fp8 | both）" >&2
      exit 2
      ;;
  esac

  echo "### Qwen-Image-Edit 修图链路（主模型量化 $quant，约 16GB）"
  # 1. 主模型（GGUF，默认 Q3_K_S 9.2GB）—— diffusion_models/ 由 extra_model_paths.yaml
  #    映射进容器，ComfyUI-GGUF 的 "Unet Loader (GGUF)" 直接能选到。
  dl "$(url unsloth/Qwen-Image-Edit-2511-GGUF "qwen-image-edit-2511-${quant}.gguf")" \
     "$MODELS/diffusion_models/qwen-image-edit-2511-${quant}.gguf"

  # 2. 文本编码器（GGUF，4.7GB）+ mmproj 视觉塔（1.3GB，缺了会坏）
  if [ "$do_text_gguf" = 1 ]; then
    dl "$(url unsloth/Qwen2.5-VL-7B-Instruct-GGUF "Qwen2.5-VL-7B-Instruct-${text_quant}.gguf")" \
       "$MODELS/text_encoders/Qwen2.5-VL-7B-Instruct-${text_quant}.gguf"
    dl "$(url unsloth/Qwen2.5-VL-7B-Instruct-GGUF mmproj-F16.gguf)" \
       "$MODELS/text_encoders/Qwen2.5-VL-7B-Instruct-mmproj-F16.gguf"
  fi

  # 3. 文本编码器 fp8 版（可选，9.4GB）：原生 CLIPLoader 直接可用、免 mmproj
  if [ "$do_text_fp8" = 1 ]; then
    dl "$(url Comfy-Org/Qwen-Image_ComfyUI split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors)" \
       "$MODELS/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
  fi

  # 4. VAE（0.25GB，主模型 / 文本编码器 / 解码共用）
  dl "$(url Comfy-Org/Qwen-Image_ComfyUI split_files/vae/qwen_image_vae.safetensors)" \
     "$MODELS/vae/qwen_image_vae.safetensors"

  # 5. Lightning 4 步 LoRA（0.81GB）：把 20 步压到 4 步，12GB 卡批量出素材必装
  if [ "$lightning" = 1 ]; then
    dl "$(url lightx2v/Qwen-Image-Edit-2511-Lightning Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors)" \
       "$MODELS/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
  fi
}

GROUP="${1:-base}"
case "$GROUP" in
  base)           download_base ;;
  extra)          download_extra ;;
  image)          download_image ;;
  qwen-edit|qwen) download_qwen_edit ;;
  all)
    download_base
    download_extra
    download_image
    download_qwen_edit
    ;;
  -h|--help|help) usage; exit 0 ;;
  *)
    echo "未知的模型类别：$GROUP（可选：base | extra | image | qwen-edit | all）" >&2
    echo >&2
    usage >&2
    exit 2
    ;;
esac

echo
echo "===== ALL DONE（$GROUP）====="
du -sh "$MODELS"/*/ 2>/dev/null || true
echo "模型目录：$MODELS（想下到别处可设 MODELS_DIR=...）"
