#!/usr/bin/env node
// comfyui-idle-free —— ComfyUI 队列空闲后自动释放常驻占用（容器内 supervisord 托管）。
//
// 为什么需要它：
//   ComfyUI 跑完一个任务**不会**释放内存/显存 —— 模型留在显存（smart memory 能留就留），
//   显存不够时也只是卸载到系统内存继续留着；节点中间结果走 RAM 压力缓存；safetensors
//   默认 mmap 读进来的页缓存同样算在容器 cgroup 内存里。官方唯一的释放口是
//   POST /free {"unload_models":true,"free_memory":true}（WebUI 的
//   「Free model and node cache」按钮就是它）。
//   于是当容器内存被限死（docker-compose.yml 的 deploy.resources.limits.memory）时，
//   跨模型族连续调用会把常驻占用越堆越高，后面的任务被换页/回收拖死甚至 OOM。
//
// 它做什么：
//   轮询 /queue，发现**队列空闲**（无 running / 无 pending）且已经空闲超过
//   COMFYUI_IDLE_FREE_SECONDS 秒，就调一次 /free 把模型与缓存还回去。释放过一次后
//   保持"上膛=false"，直到再次观察到有任务在跑，避免空闲期反复调用。
//
// 不去干扰正在跑的任务：/free 只是给 ComfyUI 的队列置 flag，flag 由 prompt_worker
//   在循环里消费；worker 正在执行任务时压根不会读 flag —— 所以即使误触发，也只会
//   在**当前任务跑完之后**才释放，不会打断推理。
//
// 用法：
//   默认           空闲守护循环（supervisord 拉起，随容器启动）
//   --free-now     立即释放一次然后退出（`pixi run free` 用它做手动释放）
//
// 环境变量：
//   COMFY_LOCAL_URL                  ComfyUI 地址，默认 http://127.0.0.1:${COMFYUI_PORT_LOCAL:-18188}
//   COMFYUI_IDLE_FREE_ENABLE         是否启用空闲自动释放，默认 true（false/0/no/off 关闭）
//   COMFYUI_IDLE_FREE_SECONDS        空闲多少秒后释放，默认 60（最小 5）
//   COMFYUI_IDLE_FREE_POLL           轮询间隔秒数，默认 3（最小 1）
//
// 日志走 stdout -> /var/log/supervisor/comfyui-idle-free.log -> ai-dock logtail ->
//   `docker logs`，与 comfyui / caddy / comfyui-mcp 汇总在一起。

import { setTimeout as sleep } from "node:timers/promises";

const COMFY_URL = (
  process.env.COMFY_LOCAL_URL || `http://127.0.0.1:${process.env.COMFYUI_PORT_LOCAL || "18188"}`
).replace(/\/+$/, "");

const FREE_NOW = process.argv.includes("--free-now");
const ENABLED = !/^(0|false|no|off)$/i.test(process.env.COMFYUI_IDLE_FREE_ENABLE ?? "true");
const IDLE_SECONDS = clampInt(process.env.COMFYUI_IDLE_FREE_SECONDS, 60, 5, 86400);
const IDLE_MS = IDLE_SECONDS * 1000;
const POLL_MS = clampInt(process.env.COMFYUI_IDLE_FREE_POLL, 3, 1, 3600) * 1000;
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
    const freeMb = Math.round((dev.vram_free ?? 0) / 1024 / 1024);
    const totalMb = Math.round(dev.vram_total / 1024 / 1024);
    return `${dev.name ?? "gpu"} 显存空闲 ${freeMb}MB / ${totalMb}MB`;
  } catch {
    return null;
  }
}

/** 卸载常驻模型 + 清空节点缓存（等价于 WebUI 的 Free model and node cache）。 */
async function freeNow(reason) {
  const before = await vramSnapshot();
  await api("/free", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ unload_models: true, free_memory: true }),
  });
  const after = await vramSnapshot();
  log(`已请求释放（${reason}）：释放前 ${before ?? "显存信息不可用"} → 释放后 ${after ?? "显存信息不可用"}`);
}

async function main() {
  if (FREE_NOW) {
    await freeNow("手动 --free-now");
    return;
  }

  if (!ENABLED) {
    log("COMFYUI_IDLE_FREE_ENABLE=false：空闲自动释放已关闭（进程保持存活，不退出以免 supervisord 反复重启）");
    for (;;) await sleep(3600 * 1000);
  }

  log(
    `已启用：队列空闲 ${IDLE_SECONDS}s 后自动 POST /free（轮询 ${POLL_MS / 1000}s，目标 ${COMFY_URL}）；` +
      `只想临时用可在 .env 里设 COMFYUI_IDLE_FREE_ENABLE=false`
  );

  let idleSince = null;
  let armed = true;
  let lastErrorLogAt = 0;

  for (;;) {
    try {
      const queue = await api("/queue");
      const busyCount = (queue?.queue_running?.length ?? 0) + (queue?.queue_pending?.length ?? 0);

      if (busyCount > 0) {
        idleSince = null;
        armed = true; // 又跑起来了：下一次空闲可以再释放一遍
      } else {
        if (idleSince === null) idleSince = Date.now();
        if (armed && Date.now() - idleSince >= IDLE_MS) {
          await freeNow(`队列已空闲约 ${Math.round((Date.now() - idleSince) / 1000)}s`);
          armed = false;
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
