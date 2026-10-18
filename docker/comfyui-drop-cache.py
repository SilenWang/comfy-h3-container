#!/usr/bin/env python3
"""丢弃模型文件的页缓存（page cache），让容器 cgroup 内存真正降下来。

为什么需要：
    ComfyUI 的 POST /free 只会卸载模型对象、清空节点缓存、empties CUDA cache，
    但不会动 **文件页缓存**。safetensors / GGUF 默认走 mmap（或 read）读盘，
    读进来的页会一直挂在容器 cgroup 的 file/active_file 上 —— `docker stats`
    看到的 "MEM USAGE" 里很大一部分就是它。队列空闲时进程已经不再使用这些页，
    却要等到内核在内存压力下回收；在 24G 硬上限的容器里，这会持续挤占后续任务
    的可用内存。

这个脚本做什么：
    对模型目录下的权重文件逐个调用 posix_fadvise(POSIX_FADV_DONTNEED)，
    提示内核立刻丢弃这些文件的干净页缓存。不删除文件、不改内容、不 require root，
    只需要对文件有读权限。代价是下次加载同一模型要重新从磁盘读（NVMe 上通常
    只多几秒）。

用法：
    python3 comfyui-drop-cache.py [/path/to/models:/another/path]

环境变量：
    COMFYUI_MODEL_DIRS          模型目录，冒号分隔；默认 /workspace/models:/opt/ComfyUI/models
    COMFYUI_DROP_CACHE_MIN_MB   只处理不小于该大小的文件（MB），默认 1
    COMFYUI_CGROUP_DIR          cgroup v2 目录，默认 /sys/fs/cgroup（用于打印前后对比）

输出（stdout 一行 JSON，便于 Node 守护解析/记录）：
    {"files": N, "bytes": M, "failed": K, "file_cache_before": X, "file_cache_after": Y, "dropped_bytes": D}
    files/bytes 是**扫描到**的模型文件数量与总大小；dropped_bytes 才是本次实际丢掉的页缓存
    （file_cache_before - file_cache_after），可能远小于扫描总量。
"""

import json
import os
import sys

DEFAULT_ROOTS = "/workspace/models:/opt/ComfyUI/models"
MODEL_EXTS = {
    ".safetensors",
    ".sft",
    ".gguf",
    ".ckpt",
    ".pt",
    ".pth",
    ".bin",
}
CGROUP_DIR = os.environ.get("COMFYUI_CGROUP_DIR", "/sys/fs/cgroup")


def read_file_cache_bytes():
    """当前 cgroup 的 file 页缓存字节数（拿不到返回 None）。"""
    try:
        with open(os.path.join(CGROUP_DIR, "memory.stat"), "r", encoding="utf-8") as fh:
            for line in fh:
                key, _, value = line.partition(" ")
                if key == "file":
                    return int(value.strip())
    except (OSError, ValueError):
        pass
    return None


def iter_model_files(roots, min_bytes):
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                ext = os.path.splitext(name)[1].lower()
                if ext not in MODEL_EXTS:
                    continue
                path = os.path.join(dirpath, name)
                try:
                    size = os.stat(path).st_size
                except OSError:
                    continue
                if size < min_bytes:
                    continue
                yield path, size


def drop_cache(path):
    """对单个文件丢弃页缓存；成功返回 True（不支持时也算跳过，不算失败）。"""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        # length=0 表示从 offset 到文件末尾；DONTNEED 只丢弃干净的页缓存。
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        return True
    except (OSError, AttributeError):
        return False
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def main():
    roots = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("COMFYUI_MODEL_DIRS", DEFAULT_ROOTS)
    roots = [p for p in roots.split(os.pathsep) if p]
    try:
        min_mb = int(os.environ.get("COMFYUI_DROP_CACHE_MIN_MB", "1"))
    except ValueError:
        min_mb = 1
    min_bytes = max(0, min_mb) * 1024 * 1024

    before = read_file_cache_bytes()
    files = 0
    total = 0
    failed = 0
    for path, size in iter_model_files(roots, min_bytes):
        if drop_cache(path):
            files += 1
            total += size
        else:
            failed += 1
    after = read_file_cache_bytes()
    dropped = None
    if before is not None and after is not None:
        dropped = max(0, before - after)

    print(
        json.dumps(
            {
                "files": files,
                "bytes": total,
                "failed": failed,
                "file_cache_before": before,
                "file_cache_after": after,
                "dropped_bytes": dropped,
            }
        )
    )


if __name__ == "__main__":
    main()
