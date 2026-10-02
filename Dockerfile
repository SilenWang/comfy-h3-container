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
# 4. 安装 ComfyUI-Copilot：对话式 AI 工作流助手（阿里 AIDC，ACL 2025 Demo）
#    一句话生成 / 改写 / debug 工作流，装在现有 WebUI 里，插件式可回滚。
#    参考：https://github.com/AIDC-AI/ComfyUI-Copilot
#    注意 1：官方托管 API 已停服，必须在 WebUI 的 Copilot 面板 Settings 里
#            填自备 LLM（OpenAI 兼容端点，如 DeepSeek），或用下面的
#            CC_OPENAI_API_KEY / CC_OPENAI_BASE_URL 环境变量注入。
#    注意 2：仓库自带上游构建好的前端（dist/copilot_web），无需 npm 构建。
#    注意 3：必须先升级 pip。基础镜像自带的 pip 很旧，其解析器会在
#            sqlalchemy>=1.4,<2.0 与 fastmcp/openai-agents 的依赖间反复回溯，
#            最后尝试源码编译远古 greenlet（<0.4.17 的 setup.py 在 py3.10 下
#            语法错误）而失败。升级到新版 pip 后一次解析成功。
# ---------------------------------------------------------------
RUN git clone --depth 1 \
        https://github.com/AIDC-AI/ComfyUI-Copilot \
        /opt/ComfyUI/custom_nodes/ComfyUI-Copilot && \
    bash -c "source /opt/environments/python/comfyui/bin/activate && \
        pip install --no-cache-dir --upgrade pip && \
        pip install --no-cache-dir -r /opt/ComfyUI/custom_nodes/ComfyUI-Copilot/requirements.txt"

# ---------------------------------------------------------------
# 5. 安装 Comfy MCP Local：官方 stdio MCP server（引擎是 comfy-cli）
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
# 6. 模型路径映射：挂载卷 /workspace/models -> ComfyUI 各模型目录
# ---------------------------------------------------------------
COPY extra_model_paths.yaml /opt/ComfyUI/extra_model_paths.yaml

# ---------------------------------------------------------------
# 7. 默认环境变量（可用 docker-compose / .env 覆盖）
#    - COMFYUI_ARGS: --lowvram 按需加载/卸载（12GB 显卡实测关键参数）
#    - COMFYUI_PORT_LOCAL: 容器内 ComfyUI 监听端口（必须 != COMFYUI_PORT_HOST，
#      否则与 ai-dock 的 caddy 反向代理冲突）
#    - WEB_PASSWORD / WEB_ENABLE_AUTH: ai-dock 的 caddy 认证（详见 README）
#    - COMFY_LOCAL_URL: comfy-cli 连容器内 ComfyUI 的地址。ComfyUI 进程监听
#      COMFYUI_PORT_LOCAL(18188)，而 caddy 在 8188；容器内 MCP 直连 18188
#      可以完全绕过反代与认证。
# ---------------------------------------------------------------
ENV COMFYUI_ARGS="--listen 0.0.0.0 --lowvram"
ENV COMFYUI_PORT_LOCAL=18188
ENV COMFYUI_PORT_HOST=8188
ENV WEB_PASSWORD=comfy-h3
ENV COMFY_LOCAL_URL=http://127.0.0.1:18188

EXPOSE 8188
