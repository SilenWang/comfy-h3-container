# ComfyUI + MiniMax H3 容器镜像
# 基础镜像：ai-dock/comfyui（GitHub 最主流的 ComfyUI 容器方案）
# 参考：https://github.com/ai-dock/comfyui
FROM ghcr.io/ai-dock/comfyui:latest-cuda

# ---------------------------------------------------------------
# 1. 更新 ComfyUI 到最新版
#    MiniMax H3 原生支持要求 ComfyUI >= 0.30.0（实测 0.33.0）
# ---------------------------------------------------------------
RUN cd /opt/ComfyUI && \
    git fetch origin && \
    git checkout master && \
    git pull --ff-only origin master

# ---------------------------------------------------------------
# 2. 升级 torch 并安装 ComfyUI 依赖
#    镜像自带 torch 2.4.1 与 comfy-kitchen（H3 量化算子）不兼容，
#    需 >= 2.5；实测 2.13.0+cu126 正常。xformers 与旧 torch 绑定，卸载。
# ---------------------------------------------------------------
RUN bash -c "source /opt/environments/python/comfyui/bin/activate && \
    pip install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu126 && \
    pip uninstall -y xformers && \
    pip install -r /opt/ComfyUI/requirements.txt"

# ---------------------------------------------------------------
# 3. 安装 MiniMax H3 Turbo LoRA 插件（4 步加速，实测提速 ~4.4x）
#    参考：https://github.com/larryvrh/ComfyUI-MiniMax-H3-Turbo
# ---------------------------------------------------------------
RUN git clone --depth 1 \
    https://github.com/larryvrh/ComfyUI-MiniMax-H3-Turbo \
    /opt/ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-Turbo

# ---------------------------------------------------------------
# 3b. 12GB 显存优化插件：注意力加速 + 文本编码器显式卸载
#     - ComfyUI-KJNodes：提供 `PathchSageAttentionKJ`（把模型注意力换成
#       SageAttention，唯一"不改结果"的提速手段，Ampere/Ada 约 1.3–2x）
#       https://github.com/kijai/ComfyUI-KJNodes
#     - ComfyUI-MAINodes：提供 `H3EvictTextEncoder`（conditioning 直通，
#       编码完成后立刻卸载 Qwen3-VL 文本编码器，避免采样阶段反复经 PCIe 换入换出）
#       https://github.com/matlowai/ComfyUI-MAINodes
#     - sageattention：KJ 节点的运行时依赖。PyPI 上的 sageattention 只有
#       V1（Triton，仅 `sageattn`/`sageattn_varlen`），不含工作流默认模式
#       `sageattn_qk_int8_pv_fp16_cuda` 所需的 2.x CUDA 算子，且 2.x 无 PyPI
#       wheel，因此这里从源码编译官方 v2.2.0（用 ai-dock 自带 nvcc，耗时数分钟）。
#       两处必要修补：torch>=2.4 头文件要求 C++20，需把 setup.py 的
#       -std=c++17 改为 c++20；cuSPARSE 头在 pip 包 nvidia-cusparse-cu12 内，
#       需把 site-packages/nvidia/*/include 加入编译 include 路径。
#       **注意**：源码走 codeload tarball 而不是 `git clone`。`git clone` 在部分
#       构建机上会卡在 index-pack / 超时失败，而下面用 `|| echo WARN` 做了容错，
#       于是镜像"构建成功"却漏装 sageattention，运行时报
#       ModuleNotFoundError。改 tarball + 重试可消除这个静默失败。
#       另外先装 PyPI 的 V1 作为兜底：即使 2.x 编译失败，`sageattention` 模块
#       仍可导入，把节点切到 `auto`（V1 Triton）或 `disabled` 即可无损回退。
#       最后固定 MAX_JOBS（默认 32 在部分机器上会随机编译失败），失败后降并行度重试一次。
#     两个 workflow 已内置这两个节点，无需手动接线。
# ---------------------------------------------------------------
RUN for repo in \
        "https://github.com/kijai/ComfyUI-KJNodes /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes" \
        "https://github.com/matlowai/ComfyUI-MAINodes /opt/ComfyUI/custom_nodes/ComfyUI-MAINodes"; do \
        set -- $repo; url=$1; dir=$2; \
        for i in 1 2 3 4 5; do \
            git clone --depth 1 "$url" "$dir" && break; \
            rm -rf "$dir"; echo "git clone $url 重试 $i ..."; sleep 5; \
        done; \
        test -d "$dir/.git"; \
    done && \
    bash -c "set -e && source /opt/environments/python/comfyui/bin/activate && \
        pip install --no-cache-dir --upgrade pip setuptools wheel ninja packaging && \
        pip install --no-cache-dir sageattention && \
        if ( \
          for i in 1 2 3; do \
            curl -fsSL --connect-timeout 20 --max-time 600 --speed-limit 1024 --speed-time 30 \
              --retry 3 --retry-delay 5 -o /tmp/sa2.tar.gz \
              https://codeload.github.com/thu-ml/SageAttention/tar.gz/refs/tags/v2.2.0 && break; \
            echo \"SageAttention 源码下载重试 \$i ...\"; sleep 5; \
          done && \
          gzip -t /tmp/sa2.tar.gz && \
          rm -rf /tmp/SageAttention && mkdir -p /tmp/SageAttention && \
          tar xzf /tmp/sa2.tar.gz -C /tmp/SageAttention --strip-components=1 && \
          sed -i 's/-std=c++17/-std=c++20/g' /tmp/SageAttention/setup.py && \
          NINCS=\$(for d in /opt/environments/python/comfyui/lib/python3.10/site-packages/nvidia/*/include; do printf ' -I%s' \"\$d\"; done) && \
          ( TORCH_CUDA_ARCH_LIST=8.0,8.6 MAX_JOBS=8 EXT_PARALLEL=8 CXX_APPEND_FLAGS=\"\$NINCS\" NVCC_APPEND_FLAGS=\"--threads 4 \$NINCS\" \
              pip install --no-cache-dir --no-build-isolation /tmp/SageAttention || \
            { echo '首次编译失败，清理后降低并行度重试...'; rm -rf /tmp/SageAttention/build; \
              TORCH_CUDA_ARCH_LIST=8.0,8.6 MAX_JOBS=2 EXT_PARALLEL=2 CXX_APPEND_FLAGS=\"\$NINCS\" NVCC_APPEND_FLAGS=\"--threads 4 \$NINCS\" \
                pip install --no-cache-dir --no-build-isolation /tmp/SageAttention; } \
          ) && \
          python -c 'from sageattention import sageattn_qk_int8_pv_fp16_cuda' \
        ); then \
          echo 'SageAttention v2.2.0 编译安装成功：PathchSageAttentionKJ 的 cuda 模式可用'; \
        else \
          echo 'WARN: SageAttention 2.x 构建失败，已保留 PyPI V1；请把 PathchSageAttentionKJ 节点切到 auto（V1 Triton）或 disabled，流程仍可跑'; \
        fi" && \
    chown -R 1000:1111 /opt/ComfyUI/custom_nodes/ComfyUI-KJNodes \
                      /opt/ComfyUI/custom_nodes/ComfyUI-MAINodes

# ---------------------------------------------------------------
# 4. 安装 Comfy MCP Local：官方 stdio MCP server（引擎是 comfy-cli）
#    参考：https://github.com/Comfy-Org/comfy-mcp
#    装在容器内，MCP 客户端用 `docker exec -i comfyui-h3 comfy-mcp` 调起，
#    直接驱动容器内 ComfyUI，不经过 caddy 反代，因此与 WebUI 认证无关。
#    COMFY_LOCAL_URL 见下方 ENV。
#    注意：必须一并升级 typer。comfy-cli 只要求 typer>=0.12.5，而基础镜像里
#          的旧 typer 与新版 click 不兼容，`comfy` 启动时会抛
#          "Secondary flag is not valid for non-boolean flag"。升 typer 即可。
# ---------------------------------------------------------------
RUN bash -c "source /opt/environments/python/comfyui/bin/activate && \
        pip install --no-cache-dir --upgrade pip typer && \
        pip install --no-cache-dir 'comfy-cli>=1.14.0' 'comfy-mcp'" && \
    ln -sf /opt/environments/python/comfyui/bin/comfy /usr/local/bin/comfy && \
    ln -sf /opt/environments/python/comfyui/bin/comfy-mcp /usr/local/bin/comfy-mcp && \
    bash -c "source /opt/environments/python/comfyui/bin/activate && \
        comfy set-default /opt/ComfyUI && \
        comfy --version && comfy-mcp --version"

# ---------------------------------------------------------------
# 5. 安装 artokun/comfyui-mcp：第三方 ComfyUI MCP（让 Agent 直接搭建/编辑工作流
#    并提供原生远程 HTTP），以 Node 运行，并作为容器内 supervisor 托管服务随容器启动。
#    参考：https://github.com/artokun/comfyui-mcp（npm 包 comfyui-mcp）
#    - 要求 Node >= 22：装官方 Node 22 的 linux tarball（.tar.gz，免 xz 依赖），
#      再 `npm -g` 安装固定版本 comfyui-mcp。
#    - 服务由 supervisord 拉起（docker/supervisor-comfyui-mcp.conf +
#      docker/supervisor-comfyui-mcp.sh），日志写 /var/log/supervisor/comfyui-mcp.log；
#      ai-dock 的 logtail 会把 /var/log/supervisor/*.log 汇总进 `docker logs`，
#      因此 comfyui / caddy / comfyui-mcp 的日志在容器日志里都能看到。
#    - 传输：Streamable HTTP，监听容器内 0.0.0.0:19100（由 compose 映射到宿主）。
# ---------------------------------------------------------------
ARG NODE_VERSION=v22.23.2
ARG COMFYUI_MCP_VERSION=0.52.205
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64) NODE_ARCH=x64 ;; \
        aarch64|arm64) NODE_ARCH=arm64 ;; \
        *) echo "unsupported arch: $(uname -m)"; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 --connect-timeout 20 \
        "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" -o /tmp/node.tar.gz; \
    mkdir -p /usr/local/lib/nodejs; \
    tar -xzf /tmp/node.tar.gz -C /usr/local/lib/nodejs --strip-components=1; \
    ln -sf /usr/local/lib/nodejs/bin/node /usr/local/bin/node; \
    ln -sf /usr/local/lib/nodejs/bin/npm  /usr/local/bin/npm; \
    ln -sf /usr/local/lib/nodejs/bin/npx  /usr/local/bin/npx; \
    rm -f /tmp/node.tar.gz; \
    node --version; \
    npm config set prefix /usr/local; \
    npm install -g "comfyui-mcp@${COMFYUI_MCP_VERSION}"; \
    /usr/local/bin/comfyui-mcp --help >/dev/null 2>&1 || true

COPY docker/supervisor-comfyui-mcp.conf /etc/supervisor/supervisord/conf.d/comfyui-mcp.conf
COPY docker/supervisor-comfyui-mcp.sh /opt/ai-dock/bin/supervisor-comfyui-mcp.sh
RUN chmod +x /opt/ai-dock/bin/supervisor-comfyui-mcp.sh

# ---------------------------------------------------------------
# 6. 模型路径映射：挂载卷 /workspace/models -> ComfyUI 各模型目录
# ---------------------------------------------------------------
COPY extra_model_paths.yaml /opt/ComfyUI/extra_model_paths.yaml

# ---------------------------------------------------------------
# 7. 默认环境变量（可用 docker-compose / .env 覆盖）
#    - COMFYUI_ARGS: --lowvram 按需加载/卸载（12GB 显卡实测关键参数）
#    - COMFYUI_PORT_LOCAL: 容器内 ComfyUI 监听端口（必须 != COMFYUI_PORT_HOST，
#      否则与 ai-dock 的 caddy 反向代理冲突）
#    - WEB_PASSWORD / WEB_ENABLE_AUTH: ai-dock 的 caddy 认证（详见 README）
#    - COMFY_LOCAL_URL: comfy-cli / artokun MCP 连容器内 ComfyUI 的地址。
#      ComfyUI 进程监听 COMFYUI_PORT_LOCAL(18188)，而 caddy 在 8188；容器内
#      MCP 直连 18188 可以完全绕过反代与认证。
#    - COMFYUI_MCP_PORT_LOCAL: 容器内 artokun MCP（Streamable HTTP）监听端口。
#    - COMFYUI_MCP_HTTP_TOKEN: artokun MCP 的入站鉴权令牌（Bearer / X-API-Key）。
# ---------------------------------------------------------------
ENV COMFYUI_ARGS="--listen 0.0.0.0 --lowvram"
ENV COMFYUI_PORT_LOCAL=18188
ENV COMFYUI_PORT_HOST=8188
ENV WEB_PASSWORD=comfy-h3
ENV COMFY_LOCAL_URL=http://127.0.0.1:18188
ENV COMFYUI_MCP_PORT_LOCAL=19100
ENV COMFYUI_MCP_HTTP_TOKEN=comfy-h3-mcp

EXPOSE 8188
EXPOSE 19100
