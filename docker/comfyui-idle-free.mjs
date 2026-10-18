#!/usr/bin/env node
// comfyui-idle-free —— ComfyUI 队列空闲后自动释放常驻占用（容器内 supervisord 托管）。
//
// 为什么需要它：
//   ComfyUI 跑完一个任务**不会**释放内存/显存 —— 模型留在显存（smart memory 能留就留），
//   显存不够时也只是卸载到系统内存继续留着；节点中间结果走 RAM 压力缓存；safetensors /
//   GGUF 读盘产生的**页缓存**同样算在容器 cgroup 内存里。官方唯一的释放口是
//   POST /free {"unload_models":true,"free_memory":true}（WebUI 的
//   「Free model and node cache」按钮就是它）。
//
//   ⚠️ 但 /free 只卸载模型对象 / 清空节点缓存 / 清 CUDA cache，**不会丢弃页缓存**。
//   实测：/free 后显存从 7.3GB 占用降到 0.5GB，cgroup 的 file 页缓存却一点不掉，
//   `docker stats`（cgroup memory.current）因此看起来「内存不释放」。所以本守护除了
//   /free，还会在空闲时对模型文件调 posix_fadvise(DONTNEED)，把干净的页缓存还给内核。
//
// 它做什么（按顺序）：
//   1. 轮询 /queue，发现队列空闲超过 COMFYUI_IDLE_FREE_SECONDS 秒；
//   2. 记录 cgroup 内存明细（working set / anon / file / inactive_file / pinned）；
//   3. POST /free 卸载模型、清节点缓存、清显存；再记录一次明细；
//   4. 若页缓存仍高于阈值，调用 comfyui-drop-cache.py 丢弃模型文件的页缓存；
//   5. （可选）若长时间空闲后 anon/pinned 仍然很高，用 supervisorctl 重启 ComfyUI
//      进程 —— 这是回收匿名内存/锁页内存最彻底的手段，默认关闭。
//
// 不去干扰正在跑的任务：/free 只是给 ComfyUI 的队列置 flag，flag 由 prompt_worker
//   在循环里消费；worker 正在执行任务时压根不会读 flag —— 所以即使误触发，也只会
//   在**当前任务跑完之后**才释放，不会打断推理。
//
// 用法：
//   默认              空闲守护循环（supervisord 拉起，随容器启动）
//   --free-now        立即释放一次然后退出（`pixi run free` 用它做手动释放）
//   --drop-cache      只丢弃模型文件页缓存然后退出
//   --stats           打印一次 cgroup 内存明细（JSON）然后退出
//
// 环境变量：
//   COMFY_LOCAL_URL                        ComfyUI 地址，默认 http://127.0.0.1:${COMFYUI_PORT_LOCAL:-18188}
//   COMFYUI_IDLE_FREE_ENABLE               是否启用空闲自动释放，默认 true（false/0/no/off 关闭）
//   COMFYUI_IDLE_FREE_SECONDS              空闲多少秒后释放，默认 60（最小 5）
//   COMFYUI_IDLE_FREE_POLL                 轮询间隔秒数，默认 3（最小 1）
//   COMFYUI_IDLE_FREE_SETTLE_MS            /free 后等待多久再读内存明细，默认 2000
//   COMFYUI_IDLE_FREE_DROP_FILE_CACHE      是否丢弃模型文件页缓存，默认 true
//   COMFYUI_IDLE_FREE_FILE_CACHE_MIN_MB    页缓存高于该值才丢弃（MB），默认 512
//   COMFYUI_IDLE_FREE_RESTART_SECONDS      空闲释放后再空闲多少秒重启 ComfyUI；0=关闭（默认）
//   COMFYUI_IDLE_FREE_RESTART_MIN_ANON_MB  重启阈值：anon+pinned 高于该值才重启（MB），默认 4096
//   COMFYUI_MODEL_DIRS                     模型目录（冒号分隔），默认 /workspace/models:/opt/ComfyUI/models
//   COMFYUI_PYTHON                         跑页缓存脚本的 Python，默认 /opt/environments/python/comfyui/bin/python
//   COMFYUI_CGROUP_DIR                     cgroup v2 目录，默认 /sys/fs/cgroup
//   COMFYUI_SUPERVISORCTL                  supervisorctl 路径，默认 supervisorctl
//
// 日志走 stdout -> /var/log/supervisor/comfyui-idle-free.log -> ai-dock logtail ->
//   `docker logs`，与 comfyui / caddy / comfyui-mcp 汇总在一起。

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const COMFY_URL = (
  process.env.COMFY_LOCAL_URL || `http://127.0.0.1:${process.env.COMFYUI_PORT_LOCAL || "18188"}`
).replace(/\/+$/, "");

const FREE_NOW = process.argv.includes("--free-now");
const DROP_CACHE_ONLY = process.argv.includes("--drop-cache");
const STATS_ONLY = process.argv.includes("--stats");

const ENABLED = !/^(0|false|no|off)$/i.test(process.env.COMFYUI_IDLE_FREE_ENABLE ?? "true");
const IDLE_SECONDS = clampInt(process.env.COMFYUI_IDLE_FREE_SECONDS, 60, 5, 86400);
const IDLE_MS = IDLE_SECONDS * 1000;
const POLL_MS = clampInt(process.env.COMFYUI_IDLE_FREE_POLL, 3, 1, 3600) * 1000;
const SETTLE_MS = clampInt(process.env.COMFYUI_IDLE_FREE_SETTLE_MS, 2000, 0, 60000);
const DROP_FILE_CACHE = !/^(0|false|no|off)$/i.test(process.env.COMFYUI_IDLE_FREE_DROP_FILE_CACHE ?? "true");
const FILE_CACHE_MIN_BYTES =
  clampInt(process.env.COMFYUI_IDLE_FREE_FILE_CACHE_MIN_MB, 512, 0, 1024 * 1024) * 1024 * 1024;
const RESTART_SECONDS = clampInt(process.env.COMFYUI_IDLE_FREE_RESTART_SECONDS, 0, 0, 7 * 86400);
const RESTART_MS = RESTART_SECONDS * 1000;
const RESTART_MIN_ANON_BYTES =
  clampInt(process.env.COMFYUI_IDLE_FREE_RESTART_MIN_ANON_MB, 4096, 0, 1024 * 1024) * 1024 * 1024;
const RESTART_WAIT_SECONDS = clampInt(process.env.COMFYUI_IDLE_RESTART_WAIT_SECONDS, 180, 10, 1800);

const CGROUP_DIR = process.env.COMFYUI_CGROUP_DIR || "/sys/fs/cgroup";
const MODEL_DIRS = process.env.COMFYUI_MODEL_DIRS || "/workspace/models:/opt/ComfyUI/models";
const PYTHON = process.env.COMFYUI_PYTHON || "/opt/environments/python/comfyui/bin/python";
const DROP_CACHE_SCRIPT =
  process.env.COMFYUI_DROP_CACHE_SCRIPT || "/opt/ai-dock/bin/comfyui-drop-cache.py";
const SUPERVISORCTL = process.env.COMFYUI_SUPERVISORCTL || "supervisorctl";

const REQUEST_TIMEOUT_MS = 15000;
const ERROR_LOG_INTERVAL_MS = 60000;

function clampInt(raw, fallback, min, max) {
  const n = Number.parseInt(raw ?? "", 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function log(msg) {
  console.log(`[comfyui-idle-free] ${new Date().toISOString()} ${msg}`);
}

function gib(bytes) {
  if (bytes === null || bytes === undefined || Number.isNaN(bytes)) return "n/a";
  return `${(bytes / 1024 ** 3).toFixed(2)}GB`;
}

async function api(path, init) {
  const res = await fetch(`${COMFY_URL}${path}`, {
    ...init,
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`${init?.method ?? "GET"} ${path} -> HTTP ${res.status}`);
  }
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

/** 显存快照（仅用于日志，拿不到就返回 null）。 */
async function vramSnapshot() {
  try {
    const stats = await api("/system_stats");
    const dev = stats?.devices?.[0];
    if (!dev?.vram_total) return null;
    return {
      free: dev.vram_free ?? null,
      total: dev.vram_total ?? null,
      name: dev.name ?? "gpu",
    };
  } catch {
    return null;
  }
}

function readInt(path) {
  try {
    const s = readFileSync(path, "utf8").trim();
    if (s === "max") return null;
    const n = Number.parseInt(s, 10);
    return Number.isFinite(n) ? n : null;
  } catch {
    return null;
  }
}

/** cgroup v2 内存明细；取不到就返回 null 字段。 */
function memorySnapshot() {
  const current =
    readInt(`${CGROUP_DIR}/memory.current`) ?? readInt(`${CGROUP_DIR}/memory.usage_in_bytes`);
  const max = readInt(`${CGROUP_DIR}/memory.max`) ?? readInt(`${CGROUP_DIR}/memory.limit_in_bytes`);
  const stat = {};
  try {
    for (const line of readFileSync(`${CGROUP_DIR}/memory.stat`, "utf8").split("\n")) {
      const m = line.match(/^(\S+)\s+(\d+)$/);
      if (m) stat[m[1]] = Number.parseInt(m[2], 10);
    }
  } catch {
    /* 拿不到明细就只记总量 */
  }
  const inactiveFile = stat.inactive_file ?? stat.total_inactive_file ?? null;
  return {
    current,
    max,
    // ComfyUI 的 system_memory 也是用 current - inactive_file 估算可用内存
    workingSet: current !== null ? Math.max(0, current - (inactiveFile ?? 0)) : null,
    anon: stat.anon ?? stat.total_anon ?? null,
    file: stat.file ?? null,
    activeFile: stat.active_file ?? stat.total_active_file ?? null,
    inactiveFile,
    pinned: stat.pinned ?? null,
    slab: stat.slab ?? stat.total_slab ?? null,
    shmem: stat.shmem ?? null,
  };
}

function memorySummary(mem) {
  if (!mem) return "cgroup 内存信息不可用";
  return (
    `cgroup working set ${gib(mem.workingSet)} / 上限 ${gib(mem.max)}` +
    `（anon ${gib(mem.anon)}，file ${gib(mem.file)}，inactive_file ${gib(mem.inactiveFile)}` +
    `${mem.pinned !== null ? `，pinned ${gib(mem.pinned)}` : ""}）`
  );
}

function vramSummary(vram) {
  if (!vram) return "显存信息不可用";
  return `${vram.name} 显存空闲 ${gib(vram.free)} / ${gib(vram.total)}`;
}

async function snapshot() {
  return { mem: memorySnapshot(), vram: await vramSnapshot() };
}

/** 对模型文件丢弃页缓存（调用 Python 辅助脚本；脚本缺失不算错误）。 */
function dropFileCache(reason) {
  if (!existsSync(DROP_CACHE_SCRIPT)) {
    log(`跳过页缓存回收（${reason}）：找不到 ${DROP_CACHE_SCRIPT}，镜像可能还是旧版`);
    return null;
  }
  const python = existsSync(PYTHON) ? PYTHON : "python3";
  const started = Date.now();
  const res = spawnSync(python, [DROP_CACHE_SCRIPT], {
    encoding: "utf8",
    timeout: 120000,
    env: { ...process.env, COMFYUI_MODEL_DIRS: MODEL_DIRS },
  });
  if (res.error || res.status !== 0) {
    log(
      `页缓存回收失败（${reason}）：${res.error?.message ?? `exit ${res.status}`} ` +
        `${(res.stderr || "").trim().split("\n").slice(-2).join(" | ")}`
    );
    return null;
  }
  try {
    const out = JSON.parse((res.stdout || "").trim().split("\n").pop());
    log(
      `已丢弃模型文件页缓存（${reason}）：${out.files} 个文件、${gib(out.bytes)}，` +
        `耗时 ${Date.now() - started}ms，file 页缓存 ${gib(out.file_cache_before)} → ${gib(out.file_cache_after)}` +
        `${out.failed ? `（${out.failed} 个跳过）` : ""}`
    );
    return out;
  } catch {
    log(`页缓存回收完成（${reason}），脚本输出无法解析：${(res.stdout || "").trim().slice(0, 200)}`);
    return null;
  }
}

/**
 * 卸载常驻模型 + 清空节点缓存 + 丢弃模型页缓存。
 * 返回释放后的快照，便于调用方判断是否还需要重启进程。
 */
async function freeNow(reason) {
  const before = await snapshot();
  log(`开始释放（${reason}）：${vramSummary(before.vram)}；${memorySummary(before.mem)}`);

  await api("/free", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ unload_models: true, free_memory: true }),
  });

  // /free 是给 prompt worker 置 flag，等它处理完 + gc.collect 后再读数据
  await sleep(SETTLE_MS);
  const afterFree = await snapshot();
  log(`/free 完成：${vramSummary(afterFree.vram)}；${memorySummary(afterFree.mem)}`);

  if (DROP_FILE_CACHE && afterFree.mem?.file !== null && afterFree.mem?.file >= FILE_CACHE_MIN_BYTES) {
    dropFileCache("队列空闲");
    await sleep(500);
    const afterDrop = memorySnapshot();
    log(`页缓存回收后：${memorySummary(afterDrop)}`);
    return { afterFree, afterDrop };
  }

  if (afterFree.mem?.file !== null && afterFree.mem?.file < FILE_CACHE_MIN_BYTES) {
    log(`页缓存低于阈值 ${gib(FILE_CACHE_MIN_BYTES)}，跳过丢弃`);
  }
  return { afterFree, afterDrop: afterFree.mem };
}

async function restartComfyUI(reason) {
  log(`重启 ComfyUI 进程以回收匿名/锁页内存（${reason}）`);
  const res = spawnSync(SUPERVISORCTL, ["restart", "comfyui"], {
    encoding: "utf8",
    timeout: 120000,
  });
  if (res.error || res.status !== 0) {
    log(
      `重启失败：${res.error?.message ?? `exit ${res.status}`} ` +
        `${(res.stderr || "").trim().split("\n").slice(-2).join(" | ")}`
    );
    return false;
  }
  // 等 ComfyUI 的 HTTP 服务重新可用
  const deadline = Date.now() + RESTART_WAIT_SECONDS * 1000;
  while (Date.now() < deadline) {
    try {
      await api("/system_stats");
      await sleep(1000);
      log(`ComfyUI 已重新启动：${memorySummary(memorySnapshot())}`);
      return true;
    } catch {
      await sleep(2000);
    }
  }
  log(`ComfyUI 重启后 ${RESTART_WAIT_SECONDS}s 内仍未就绪，继续守护`);
  return false;
}

async function main() {
  if (STATS_ONLY) {
    console.log(JSON.stringify({ mem: memorySnapshot(), vram: await vramSnapshot() }, null, 2));
    return;
  }

  if (DROP_CACHE_ONLY) {
    dropFileCache("手动 --drop-cache");
    return;
  }

  if (FREE_NOW) {
    await freeNow("手动 --free-now");
    return;
  }

  if (!ENABLED) {
    log("COMFYUI_IDLE_FREE_ENABLE=false：空闲自动释放已关闭（进程保持存活，不退出以免 supervisord 反复重启）");
    for (;;) await sleep(3600 * 1000);
  }

  log(
    `已启用：队列空闲 ${IDLE_SECONDS}s 后自动 /free` +
      `${DROP_FILE_CACHE ? " + 丢弃模型页缓存" : ""}` +
      `${RESTART_SECONDS > 0 ? `；再空闲 ${RESTART_SECONDS}s 且匿名内存 > ${gib(RESTART_MIN_ANON_BYTES)} 时重启 ComfyUI` : ""}` +
      `（轮询 ${POLL_MS / 1000}s，目标 ${COMFY_URL}）`
  );

  let idleSince = null;
  let armed = true;
  let lastFreeAt = null;
  let restarted = false;
  let lastErrorLogAt = 0;

  for (;;) {
    try {
      const queue = await api("/queue");
      const busyCount = (queue?.queue_running?.length ?? 0) + (queue?.queue_pending?.length ?? 0);

      if (busyCount > 0) {
        idleSince = null;
        armed = true; // 又跑起来了：下一次空闲可以再释放一遍
        lastFreeAt = null;
        restarted = false;
      } else {
        if (idleSince === null) idleSince = Date.now();

        if (armed && Date.now() - idleSince >= IDLE_MS) {
          await freeNow(`队列已空闲约 ${Math.round((Date.now() - idleSince) / 1000)}s`);
          armed = false;
          lastFreeAt = Date.now();
        } else if (!armed && !restarted && RESTART_MS > 0 && Date.now() - lastFreeAt >= RESTART_MS) {
          const mem = memorySnapshot();
          const reclaimable = (mem.anon ?? 0) + (mem.pinned ?? 0);
          if (reclaimable >= RESTART_MIN_ANON_BYTES) {
            // 重启前再确认一次队列确实是空的，避免和刚提交的任务撞车
            const q = await api("/queue");
            const busy = (q?.queue_running?.length ?? 0) + (q?.queue_pending?.length ?? 0);
            if (busy === 0) {
              const before = memorySnapshot();
              const ok = await restartComfyUI(
                `空闲 ${Math.round((Date.now() - idleSince) / 1000)}s，anon+pinned ${gib(reclaimable)}`
              );
              if (ok) {
                armed = true; // 重启后重新上膛，后续空闲可以再释放一轮
                idleSince = Date.now();
                lastFreeAt = null;
                // 重启会解除 ComfyUI 对模型文件的 mmap；此时再丢一次页缓存最彻底
                if (DROP_FILE_CACHE) {
                  dropFileCache("重启后");
                  await sleep(500);
                }
              }
              restarted = true;
              log(`重启前后对比：${memorySummary(before)} → ${memorySummary(memorySnapshot())}`);
            }
          } else {
            log(`匿名内存仅 ${gib(reclaimable)}（阈值 ${gib(RESTART_MIN_ANON_BYTES)}），不需要重启`);
            restarted = true;
          }
        }
      }
    } catch (err) {
      // ComfyUI 还没起来 / 正在重启 / 临时不可达：限频记日志，继续重试。
      if (Date.now() - lastErrorLogAt > ERROR_LOG_INTERVAL_MS) {
        lastErrorLogAt = Date.now();
        log(`查询 ComfyUI 失败（稍后重试）：${err?.message ?? err}`);
      }
      idleSince = null;
    }

    await sleep(POLL_MS);
  }
}

main().catch((err) => {
  log(`致命错误：${err?.stack ?? err}`);
  process.exit(1);
});
