# 部署与运维

## 0. 环境准备

| 项目 | 要求 |
|---|---|
| GPU | NVIDIA 显卡；12GB 显存为实测可用下限（RTX 3060） |
| 系统内存 | 32GB 起，64GB 更稳（offload） |
| 磁盘 | 至少 45GB 可用（二次元生图另加约 7GB，Qwen 修图另加约 16GB） |
| 软件 | Docker + nvidia-container-toolkit；Linux / WSL2 |
| 可选 | [pixi](https://pixi.sh)（用 `pixi run ...` 统一入口；只用原生 `docker compose` 也可以） |

非 NVIDIA（AMD ROCm / Apple Silicon）请参考社区方案，本仓库未覆盖。

## 1. 目录准备（很重要）

挂载目录要提前以**你自己的用户**建好：

```bash
mkdir -p models output
```

若目录不存在，`docker compose` 会以 root 创建，容器内以 uid 1000 运行的 ComfyUI 会写不进去，表现为 SaveVideo 报 `PermissionError: '/opt/ComfyUI/output/video'`，或模型列表为空。

## 2. 模型下载

详见 [models.md](models.md)。最简形式：

```bash
pixi run models base       # 基础视频模型（T2V / I2V），约 43GB；不带参数 = all，约 91GB
```

## 3. 构建并启动

```bash
docker compose up -d --build    # 前台构建 + 启动
# 或走 pixi：
pixi run build && pixi run build-status   # 后台启动构建（可续建）
pixi run up                              # 构建完成后启动
```

启动完成后访问 <http://localhost:8188>。默认 `.env.example` 已关闭认证，**直接进入、无需输密码**；若 `WEB_ENABLE_AUTH=true`，账号固定为 `user`、密码为 `.env` 中的 `WEB_PASSWORD`（详见 [configuration.md](configuration.md)）。

### 镜像构建耗时较长时怎么办（推荐用可续建的后台方式）

首次构建要拉 torch cu126 + ComfyUI 依赖，可能超过一次性前台命令能跑完的时间。Docker 会把已完成的分层写进 BuildKit 缓存，所以拆成「后台启动 + 反复重跑」可以断点续建：

```bash
pixi run build          # 后台启动构建，立即返回；已在跑则直接提示
pixi run build-status   # 查看是否还在跑 + 日志尾部
pixi run build-logs     # 实时跟踪 .build/build.log
pixi run up             # 构建完成后启动容器（镜像已就绪，不再重建）
```

即使进程被环境回收，缓存仍在，重跑 `pixi run build` 会自动从上次完成的分层继续，不会从头再来。只想快速增量构建时也可以直接 `pixi run up-build`。

构建脚本（`scripts/build_image.sh`）把日志和 PID 写在 `.build/` 下，该目录已在 `.gitignore` 中。

## 4. 容器运维

```bash
pixi run up          # 启动（镜像已构建）
pixi run up-build    # 前台构建并启动
pixi run down        # 停止并移除容器
pixi run restart     # 重启 ComfyUI 容器
pixi run logs        # 跟踪容器日志（comfyui + caddy + comfyui-mcp 汇总）
```

生成结果落在宿主的 `./output/`；用户工作流落在 `./workflows/`（仓库自带模板 + WebUI 里保存的工作流）。

### 容器内服务（supervisor）

ai-dock 基础镜像用 supervisord 托管容器内服务，日志统一进 `docker logs`：

```bash
docker exec -it comfyui-h3 supervisorctl status
docker exec -it comfyui-h3 tail -f /var/log/supervisor/comfyui-mcp.log
docker exec comfyui-h3 tail -f /var/log/supervisor/caddy.log
```

## 5. 用外部模型目录（避免每次重新下载）

模型本来就存在挂载卷里，容器重建不会丢。默认落在仓库内的 `./models`；如果想多个项目 / 多台机器共用同一份模型（比如放在 NAS 或大盘上），把 `MODELS_DIR` 指向外部目录即可：

```bash
# .env
MODELS_DIR=/data/ai-models/comfy-h3
OUTPUT_DIR=/data/ai-output/comfy-h3      # 可选，同理
```

`docker-compose.yml` 用的是 `${MODELS_DIR:-./models}`，所以不设就是原来的 `./models`，设了就挂外部目录到容器内的 `/workspace/models`。下载脚本也认同一个变量，直接把模型下到外部盘：

```bash
MODELS_DIR=/data/ai-models/comfy-h3 pixi run models base
```

两个注意点（就是之前踩过的坑）：

1. **目录要提前以你自己的用户建好**（`mkdir -p /data/ai-models/comfy-h3`）。目录不存在时 Docker 会以 root 创建 bind 源，容器内以 uid 1000 运行的 ComfyUI 会读不到 / 写不进。
2. 只读共享盘可以把它挂成只读，在 compose 里写 `"${MODELS_DIR}:/workspace/models:ro"`；下载仍在宿主侧写这个目录，不受影响。
