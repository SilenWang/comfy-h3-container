#!/usr/bin/env bash
# 把最新的 comfyui-idle-free 守护 + 页缓存回收脚本热更新进**正在运行**的容器，
# 不需要重建镜像（适合已部署的旧镜像）。改完会 reread/update supervisord 并重启
# 守护进程；ComfyUI 本体不受影响。
#
# 用法：bash scripts/mem_install.sh [容器名]（默认 comfyui-h3，可用 pixi run mem-install 调用）
set -euo pipefail

CONTAINER="${1:-comfyui-h3}"
cd "$(dirname "$0")/.."

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "找不到容器 $CONTAINER（用 docker ps 确认容器名）" >&2
  exit 1
fi

echo "→ 复制脚本到容器 $CONTAINER"
docker cp docker/comfyui-idle-free.mjs "$CONTAINER:/opt/ai-dock/bin/comfyui-idle-free.mjs"
docker cp docker/comfyui-drop-cache.py "$CONTAINER:/opt/ai-dock/bin/comfyui-drop-cache.py"
docker cp docker/supervisor-comfyui-idle-free.conf "$CONTAINER:/etc/supervisor/supervisord/conf.d/comfyui-idle-free.conf"
docker exec -u root "$CONTAINER" chmod +x /opt/ai-dock/bin/comfyui-idle-free.mjs /opt/ai-dock/bin/comfyui-drop-cache.py

echo "→ 让 supervisord 重新加载配置"
docker exec -u root "$CONTAINER" supervisorctl reread
docker exec -u root "$CONTAINER" supervisorctl update
docker exec -u root "$CONTAINER" sh -c 'supervisorctl restart comfyui-idle-free || true'

echo
echo "完成。查看状态与内存明细：bash scripts/mem_status.sh $CONTAINER"
echo "手动立即释放一次：docker exec -u root $CONTAINER /usr/local/bin/node /opt/ai-dock/bin/comfyui-idle-free.mjs --free-now"
