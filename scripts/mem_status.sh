#!/usr/bin/env bash
# 查看 ComfyUI 容器的内存明细：cgroup 工作集 / anon / file / inactive_file / pinned、
# 显存、idle-free 守护状态与最近日志。排查「跑完任务内存不释放」时先跑这个。
#
# 用法：bash scripts/mem_status.sh [容器名]（默认 comfyui-h3，可用 pixi run mem-status 调用）
set -euo pipefail

CONTAINER="${1:-comfyui-h3}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "找不到容器 $CONTAINER（用 docker ps 确认容器名）" >&2
  exit 1
fi

echo "== supervisor =="
docker exec -u root "$CONTAINER" sh -c 'supervisorctl status comfyui-idle-free || true'
echo
echo "== cgroup 内存明细 =="
docker exec -u root "$CONTAINER" sh -c '
  printf "memory.current = "; cat /sys/fs/cgroup/memory.current
  printf "memory.max     = "; cat /sys/fs/cgroup/memory.max
  grep -E "^(anon|file|active_file|inactive_file|pinned|slab|shmem) " /sys/fs/cgroup/memory.stat || true
'
echo
echo "== ComfyUI 快照（队列 / 显存 / cgroup） =="
docker exec -u root "$CONTAINER" sh -c '
  if [ -x /opt/ai-dock/bin/comfyui-idle-free.mjs ]; then
    /usr/local/bin/node /opt/ai-dock/bin/comfyui-idle-free.mjs --stats || true
  else
    echo "idle-free 脚本不存在：镜像可能是旧版，先 pixi run mem-install 或重建镜像"
  fi
'
echo
echo "== idle-free 最近日志 =="
docker exec -u root "$CONTAINER" sh -c 'tail -n 30 /var/log/supervisor/comfyui-idle-free.log 2>/dev/null || echo "(还没有日志)"'
