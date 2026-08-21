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
# 4. 模型路径映射：挂载卷 /workspace/models -> ComfyUI 各模型目录
# ---------------------------------------------------------------
COPY extra_model_paths.yaml /opt/ComfyUI/extra_model_paths.yaml

# ---------------------------------------------------------------
# 5. 默认环境变量（可用 docker-compose / .env 覆盖）
#    - COMFYUI_ARGS: --lowvram 按需加载/卸载（12GB 显卡实测关键参数）
#    - COMFYUI_PORT_LOCAL: 容器内 ComfyUI 监听端口（必须 != COMFYUI_PORT_HOST，
#      否则与 ai-dock 的 caddy 反向代理冲突）
#    - WEB_PASSWORD: WebUI 访问密码（建议在 .env 中修改）
# ---------------------------------------------------------------
ENV COMFYUI_ARGS="--listen 0.0.0.0 --lowvram"
ENV COMFYUI_PORT_LOCAL=18188
ENV COMFYUI_PORT_HOST=8188
ENV WEB_PASSWORD=comfy-h3

EXPOSE 8188
