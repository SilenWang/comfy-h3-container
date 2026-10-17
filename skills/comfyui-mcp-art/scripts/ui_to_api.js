#!/usr/bin/env node
// Convert a ComfyUI UI-format workflow (workflows/*.json) into the API-format
// prompt that the comfyui MCP's `enqueue_workflow` accepts.
//
//   node ui_to_api.js <workflow.json> [overrides.json] [--object-info-file f.json]
//
// overrides.json:
//   { "nodes": { "5": { "image": "shot.png" }, "10": { "prompt": "..." } },
//     "modes": { "17": 0, "18": 0 } }      // 0 = active, 4 = bypass
//
// Widget names come from ComfyUI's /object_info. Base URL is read from
// COMFY_HOST (default http://127.0.0.1:8188) — never hard-code remote hosts or
// tokens here. Only prints JSON; does not submit anything.
const fs = require("fs");

const HOST = process.env.COMFY_HOST || "http://127.0.0.1:8188";
const PRIMITIVES = new Set(["INT", "FLOAT", "STRING", "BOOLEAN", "COMBO"]);

function arg(name) {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : undefined;
}

async function loadObjectInfo() {
  const file = arg("--object-info-file");
  if (file) return JSON.parse(fs.readFileSync(file, "utf8"));
  const res = await fetch(`${HOST}/object_info`);
  if (!res.ok) throw new Error(`GET ${HOST}/object_info -> ${res.status}`);
  return res.json();
}

// Widget inputs in UI order, excluding connection-only inputs. Some nodes add a
// hidden "control_after_generate" value right after a seed widget.
function widgetNames(info) {
  const out = [];
  for (const group of [info.input.required || {}, info.input.optional || {}]) {
    for (const [name, spec] of Object.entries(group)) {
      const type = spec[0];
      const cfg = spec[1] || {};
      const isWidget = (typeof type === "string" && PRIMITIVES.has(type)) || Array.isArray(type);
      if (!isWidget || cfg.forceInput) continue;
      out.push({ name, control: !!cfg.control_after_generate });
    }
  }
  return out;
}

function buildPrompt(ui, overrides, objectInfo) {
  const nodes = JSON.parse(JSON.stringify(ui));
  for (const [id, mode] of Object.entries(overrides.modes || {})) {
    const n = nodes.nodes.find((x) => String(x.id) === String(id));
    if (!n) throw new Error(`mode override for missing node ${id}`);
    n.mode = mode;
  }
  const byId = new Map(nodes.nodes.map((n) => [n.id, n]));

  // A bypassed node (mode 4) passes its first input straight to output 0.
  const resolveSource = (nodeId, slot) => {
    for (let guard = 0; guard < 20; guard++) {
      const n = byId.get(nodeId);
      if (!n) throw new Error(`unknown node ${nodeId}`);
      if (n.mode !== 4) return [String(nodeId), slot];
      const src = (n.inputs || [])[0];
      if (!src || src.link == null) throw new Error(`cannot bypass node ${nodeId}`);
      const link = nodes.links.find((l) => l[0] === src.link);
      nodeId = link[1];
      slot = link[2];
    }
    throw new Error("bypass loop");
  };

  const prompt = {};
  for (const n of nodes.nodes) {
    if (n.mode === 4 || n.mode === 2) continue; // bypassed / muted
    const info = objectInfo[n.type];
    if (!info) continue; // notes and frontend-only nodes never reach the API
    const names = widgetNames(info);
    const linkInputs = new Set((n.inputs || []).map((i) => i.name));
    const widgets = n.widgets_values || [];
    const inputs = {};
    let vi = 0;
    for (const { name, control } of names) {
      if (linkInputs.has(name)) continue; // exposed as a connection here
      if (vi < widgets.length) inputs[name] = widgets[vi];
      vi += 1;
      if (control) vi += 1;
    }
    for (const inp of n.inputs || []) {
      if (inp.link == null) continue;
      const link = nodes.links.find((l) => l[0] === inp.link);
      if (!link) throw new Error(`node ${n.id}: dangling link ${inp.link}`);
      const [srcId, srcSlot] = resolveSource(link[1], link[2]);
      inputs[inp.name] = [srcId, srcSlot];
    }
    prompt[String(n.id)] = { class_type: n.type, inputs, _meta: { title: n.title || n.type } };
  }

  for (const [id, patch] of Object.entries(overrides.nodes || {})) {
    if (!prompt[id]) throw new Error(`override for missing node ${id} (bypassed or muted?)`);
    Object.assign(prompt[id].inputs, patch);
  }
  return prompt;
}

async function main() {
  const uiPath = process.argv[2];
  if (!uiPath) {
    console.error("usage: node ui_to_api.js <workflow.json> [overrides.json] [--object-info-file f.json]");
    process.exit(1);
  }
  const overridesPath = process.argv[3] && !process.argv[3].startsWith("--") ? process.argv[3] : undefined;
  const ui = JSON.parse(fs.readFileSync(uiPath, "utf8"));
  const overrides = overridesPath ? JSON.parse(fs.readFileSync(overridesPath, "utf8")) : {};
  const prompt = buildPrompt(ui, overrides, await loadObjectInfo());
  process.stdout.write(JSON.stringify({ prompt }, null, 2) + "\n");
}

main().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
