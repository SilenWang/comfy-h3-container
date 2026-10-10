#!/usr/bin/env bash
# 在「正在运行的」ComfyUI 容器内现场编译安装 SageAttention v2.2.0。
#
# 用途：修复既有容器里 PathchSageAttentionKJ 节点报
#   ModuleNotFoundError: No module named 'sageattention'
# 无需重建 ~19GB 镜像，几分钟即可装好（RTX 3060 / sm_86 实测约 4 分钟）。
#
# 用法：
#   ./scripts/install_sageattention.sh            # 默认容器名 comfyui-h3
#   ./scripts/install_sageattention.sh <容器名>    # 自定义容器名
#   pixi run fix-sage-attn
#
# 装好后 ComfyUI 无需重启：KJNodes 是在节点执行时才 import sageattention，
# 直接在 WebUI 里重新 Queue 工作流即可。
set -euo pipefail

CONTAINER="${1:-comfyui-h3}"
ENVDIR="/opt/environments/python/comfyui"
PYBIN="$ENVDIR/bin"
SITE_PACKAGES="$ENVDIR/lib/python3.10/site-packages"
ARCH="${TORCH_CUDA_ARCH_LIST:-8.0,8.6}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "错误：找不到容器 '$CONTAINER'。先启动容器，或用参数指定容器名。" >&2
  exit 1
fi

echo "==> 在容器 $CONTAINER 内安装 SageAttention v2.2.0（目标 arch: $ARCH）"
docker exec "$CONTAINER" bash -lc "
  set -euo pipefail
  source $PYBIN/activate
  # 网络抖动很常见，所有 pip 安装都带重试
  pip_retry() {
    local n=0
    until \"\$@\"; do
      n=\$((n+1)); [ \$n -ge 3 ] && return 1
      echo \"命令失败（第 \$n 次），5s 后重试...\"; sleep 5
    done
  }
  pip_retry pip install --no-cache-dir --upgrade pip setuptools wheel ninja packaging
  # 先装 PyPI V1 兜底：即使 2.x 编译失败，sageattention 模块仍可导入
  pip_retry pip install --no-cache-dir sageattention
  for i in 1 2 3; do
    # --connect-timeout/--speed-* 防止网络卡住时 curl 永久挂起（没有任何进度输出）
    curl -fsSL --connect-timeout 20 --max-time 600 --speed-limit 1024 --speed-time 30 \
      --retry 3 --retry-delay 5 -o /tmp/sa2.tar.gz \
      https://codeload.github.com/thu-ml/SageAttention/tar.gz/refs/tags/v2.2.0 && break
    echo \"源码下载重试 \$i ...\"; sleep 5
  done
  gzip -t /tmp/sa2.tar.gz || { echo \"错误：SageAttention 源码包下载不完整\" >&2; exit 1; }
  rm -rf /tmp/SageAttention && mkdir -p /tmp/SageAttention
  tar xzf /tmp/sa2.tar.gz -C /tmp/SageAttention --strip-components=1
  sed -i 's/-std=c++17/-std=c++20/g' /tmp/SageAttention/setup.py
  # 注意：site-packages 在 $ENVDIR/lib 下，不在 $PYBIN 下；写错路径会导致
  # nvcc 找不到 cusparse.h（fatal error: cusparse.h: No such file or directory）。
  NINCS=\$(for d in $SITE_PACKAGES/nvidia/*/include; do if [ -d \"\$d\" ]; then printf ' -I%s' \"\$d\"; fi; done)
  [ -n \"\$NINCS\" ] || { echo '错误：找不到 nvidia/*/include（cuSPARSE 头），无法编译' >&2; exit 1; }
  # 限制编译并行度：默认 MAX_JOBS=32 在部分机器上会因瞬时内存/文件句柄耗尽
  # 而随机编译失败，固定到 8 更稳。失败后降并行度整体重编一次。
  _build() {
    TORCH_CUDA_ARCH_LIST=$ARCH MAX_JOBS=\$1 EXT_PARALLEL=\$1 \
      CXX_APPEND_FLAGS=\"\$NINCS\" NVCC_APPEND_FLAGS=\"--threads 4 \$NINCS\" \
      pip install --no-cache-dir --no-build-isolation /tmp/SageAttention
  }
  _build 8 || { echo '首次编译失败，清理后降低并行度重试...'; rm -rf /tmp/SageAttention/build; _build 2; }
"

echo "==> 校验 import"
docker exec "$CONTAINER" bash -lc "
  source $PYBIN/activate
  python -c 'from sageattention import sageattn_qk_int8_pv_fp16_cuda, sageattn; print(\"SageAttention OK\")'
"

echo "==> 完成。ComfyUI 无需重启，直接在 WebUI 重新 Queue 工作流即可。"
