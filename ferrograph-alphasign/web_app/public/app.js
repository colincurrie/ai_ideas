"use strict";

const state = { options: null };

async function fetchJSON(url, opts) {
  const res = await fetch(url, opts);
  let body = {};
  try { body = await res.json(); } catch (e) { /* empty body */ }
  return { ok: res.ok, status: res.status, body };
}

function populateSelect(select, names, selected) {
  select.innerHTML = "";
  (names || []).forEach((name) => {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name.replace(/_/g, " ");
    select.appendChild(opt);
  });
  if (selected) select.value = selected;
}

// Rough visual approximation only - the Aurora 63 only has red/green LEDs,
// so every named color on the wire is really some combination of those.
function swatchColor(name) {
  if (!name) return "#e8e8e8";
  if (/red/.test(name)) return "#ff5a5a";
  if (/green/.test(name)) return "#5aff8a";
  if (/yellow|amber|brown|orange/.test(name)) return "#ffe45a";
  return "#c58aff"; // rainbow/mix/auto/stripe families
}

function escapeHtml(s) {
  const div = document.createElement("div");
  div.textContent = s;
  return div.innerHTML;
}

function showBytes(id, hex) {
  const pre = document.getElementById(id);
  pre.hidden = false;
  pre.textContent = hex;
}

function flashError(msg) {
  document.getElementById("compose-error").textContent = msg;
}

function clearError() {
  document.getElementById("compose-error").textContent = "";
}

async function loadOptions() {
  const { ok, body } = await fetchJSON("/api/options");
  if (!ok) {
    flashError(`Could not load fonts/colors/positions/effects: ${body.error || "serial-api unreachable"}. Is serial_api running?`);
    return;
  }
  state.options = body;
  populateSelect(document.getElementById("font-select"), body.fonts, "seven_high");
  populateSelect(document.getElementById("color-select"), body.colors, "red");
  populateSelect(document.getElementById("position"), body.positions, "fill");
  populateSelect(document.getElementById("mode"), body.modes, "automode");

  const labelSelect = document.getElementById("label");
  labelSelect.innerHTML = "";
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("").forEach((letter) => {
    const opt = document.createElement("option");
    opt.value = letter;
    opt.textContent = letter;
    labelSelect.appendChild(opt);
  });

  const imageLabelSelect = document.getElementById("image-label");
  imageLabelSelect.innerHTML = "";
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("").forEach((letter) => {
    const opt = document.createElement("option");
    opt.value = letter;
    opt.textContent = letter;
    imageLabelSelect.appendChild(opt);
  });
  imageLabelSelect.value = "P";
}

async function refreshStatus() {
  const { ok, body } = await fetchJSON("/api/status");
  const dot = document.getElementById("status-dot");
  const text = document.getElementById("status-text");

  // A failed call means serial_api itself is unreachable - a different,
  // more urgent problem than "serial_api is fine but the sign's port
  // hasn't been opened yet" (body.connected === false on a successful
  // call). Keeping these visually distinct avoids the confusing case
  // where "the whole service is down" reads identically to "totally
  // normal, nothing sent yet."
  if (!ok) {
    dot.className = "dot bad";
    text.textContent = body.error || "serial-api unreachable";
    return;
  }

  if (body.connected) {
    dot.className = "dot ok";
    const parityCode = (body.parity || "?")[0].toUpperCase();
    text.textContent = `Connected · ${body.device} @ ${body.baud} ${body.data_bits}${parityCode}${body.stop_bits} · addr ${body.address}`;
  } else {
    dot.className = "dot bad";
    text.textContent = body.last_error
      ? `Not connected · ${body.last_error}`
      : `Not connected yet · will open ${body.device || "the port"} on first send`;
  }
}

async function refreshMessages() {
  const { body } = await fetchJSON("/api/messages");
  const list = document.getElementById("labels-list");
  const empty = document.getElementById("labels-empty");
  const messages = body.messages || {};
  const labels = Object.keys(messages).sort();

  list.innerHTML = "";
  empty.hidden = labels.length > 0;

  labels.forEach((label) => {
    const msg = messages[label];
    const isImage = msg.type === "image";
    const preview = isImage ? `\u{1F5BC} image, ${msg.width}×${msg.height}` : (msg.runs || []).map((r) => r.text).join("");

    const li = document.createElement("li");

    const contentSpan = document.createElement("span");
    contentSpan.className = "content";
    const tag = document.createElement("span");
    tag.className = "label-tag";
    tag.textContent = label;
    contentSpan.appendChild(tag);
    contentSpan.appendChild(document.createTextNode(preview));
    li.appendChild(contentSpan);

    const btns = document.createElement("span");
    btns.className = "btns";

    if (!isImage) {
      const editBtn = document.createElement("button");
      editBtn.type = "button";
      editBtn.textContent = "Edit";
      editBtn.addEventListener("click", () => loadMessageIntoEditor(label, msg));
      btns.appendChild(editBtn);
    }

    const clearBtn = document.createElement("button");
    clearBtn.type = "button";
    clearBtn.className = "danger";
    clearBtn.textContent = "Clear";
    clearBtn.addEventListener("click", () => clearLabel(label));
    btns.appendChild(clearBtn);

    li.appendChild(btns);
    list.appendChild(li);
  });
}

function loadMessageIntoEditor(label, msg) {
  document.getElementById("label").value = label;
  document.getElementById("priority").checked = !!msg.priority;
  if (msg.position) document.getElementById("position").value = msg.position;
  if (msg.mode) document.getElementById("mode").value = msg.mode;
  document.getElementById("speed").value = msg.speed || "";

  const editor = document.getElementById("editor");
  editor.innerHTML = "";
  (msg.runs || []).forEach((run) => {
    if (run.color || run.font) {
      const span = document.createElement("span");
      if (run.color) {
        span.dataset.color = run.color;
        span.style.color = swatchColor(run.color);
      }
      if (run.font) {
        span.dataset.font = run.font;
        span.style.fontStyle = "italic";
      }
      span.textContent = run.text;
      editor.appendChild(span);
    } else {
      editor.appendChild(document.createTextNode(run.text));
    }
  });
}

// --- Rich text formatting (color/font runs) ---

document.getElementById("apply-format").addEventListener("click", () => {
  const sel = window.getSelection();
  const editor = document.getElementById("editor");
  if (!sel.rangeCount || sel.isCollapsed) {
    flashError("Select some text in the message first.");
    return;
  }
  const range = sel.getRangeAt(0);
  if (!editor.contains(range.commonAncestorContainer)) return;

  clearError();
  const color = document.getElementById("color-select").value;
  const font = document.getElementById("font-select").value;
  const span = document.createElement("span");
  span.dataset.color = color;
  span.dataset.font = font;
  span.style.color = swatchColor(color);
  span.style.fontStyle = "italic";
  const content = range.extractContents();
  span.appendChild(content);
  range.insertNode(span);
  sel.removeAllRanges();
});

document.getElementById("clear-format").addEventListener("click", () => {
  const sel = window.getSelection();
  const editor = document.getElementById("editor");
  if (!sel.rangeCount || sel.isCollapsed) return;
  const range = sel.getRangeAt(0);
  if (!editor.contains(range.commonAncestorContainer)) return;

  const text = range.toString();
  range.deleteContents();
  range.insertNode(document.createTextNode(text));
  sel.removeAllRanges();
});

// Walks the editor's DOM, turning nested <span data-color data-font> runs
// into the flat {text, color, font} list the API expects. A span's
// formatting applies to its whole subtree unless overridden by a nested
// span, matching how the wire protocol's control codes persist until
// changed.
function serializeEditor() {
  const runs = [];
  function walk(node, color, font) {
    if (node.nodeType === Node.TEXT_NODE) {
      if (node.textContent.length) runs.push({ text: node.textContent, color, font });
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const c = (node.dataset && node.dataset.color) || color;
    const f = (node.dataset && node.dataset.font) || font;
    node.childNodes.forEach((child) => walk(child, c, f));
  }
  document.getElementById("editor").childNodes.forEach((n) => walk(n, null, null));
  return runs;
}

// --- Compose actions ---

function buildMessagePayload(dryRun) {
  return {
    label: document.getElementById("label").value,
    priority: document.getElementById("priority").checked,
    position: document.getElementById("position").value,
    mode: document.getElementById("mode").value,
    speed: document.getElementById("speed").value || null,
    runs: serializeEditor(),
    dry_run: dryRun
  };
}

async function sendMessage(dryRun) {
  clearError();
  const payload = buildMessagePayload(dryRun);
  const path = payload.priority ? "/api/priority" : "/api/messages";
  const { ok, body } = await fetchJSON(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (!ok) {
    flashError(body.error || "Request failed");
    return;
  }
  showBytes("bytes-preview", body.bytes_hex);
  if (!dryRun) {
    await refreshMessages();
    await refreshStatus();
  }
}

async function clearLabel(label) {
  clearError();
  const { ok, body } = await fetchJSON(`/api/messages/${encodeURIComponent(label)}`, { method: "DELETE" });
  if (!ok) {
    flashError(body.error || "Request failed");
    return;
  }
  showBytes("bytes-preview", body.bytes_hex);
  await refreshMessages();
  await refreshStatus();
}

document.getElementById("preview-btn").addEventListener("click", () => sendMessage(true));
document.getElementById("send-btn").addEventListener("click", () => sendMessage(false));
document.getElementById("clear-btn").addEventListener("click", () => clearLabel(document.getElementById("label").value));

// --- Advanced: raw command ---

async function sendRaw(dryRun) {
  const payload = {
    command_code: document.getElementById("raw-command").value,
    data: document.getElementById("raw-data").value,
    dry_run: dryRun
  };
  const { ok, body } = await fetchJSON("/api/raw", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  const pre = document.getElementById("raw-bytes-preview");
  pre.hidden = false;
  pre.textContent = ok ? body.bytes_hex : `Error: ${body.error || "request failed"}`;
}

document.getElementById("raw-preview-btn").addEventListener("click", () => sendRaw(true));
document.getElementById("raw-send-btn").addEventListener("click", () => sendRaw(false));

// --- Image (client-side resize + dither to the sign's palette) ---
//
// Everything from file load through dithering happens in the browser -
// serial_api never sees raw image bytes, only the final width/height/pixel
// grid, which keeps that service free of any image-processing dependency.
// The palette approximates the sign's real red/green/yellow LEDs closely
// enough for perceptually reasonable dithering; it doesn't need to be exact.

const DOTS_PALETTE = { off: [0, 0, 0], red: [255, 50, 50], green: [50, 220, 90], yellow: [230, 195, 30] };
const DOTS_ORDER = ["off", "red", "green", "yellow"]; // index == the wire's pixel digit code
const DOTS_PREVIEW_COLORS = ["#000", "#ff5a5a", "#5aff8a", "#ffe45a"];

let loadedImage = null;

function nearestDotsColorIndex(r, g, b) {
  let best = 0;
  let bestDist = Infinity;
  DOTS_ORDER.forEach((name, i) => {
    const [pr, pg, pb] = DOTS_PALETTE[name];
    const dist = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2;
    if (dist < bestDist) {
      bestDist = dist;
      best = i;
    }
  });
  return best;
}

function distributeError(buf, width, height, x, y, er, eg, eb) {
  const add = (xx, yy, factor) => {
    if (xx < 0 || xx >= width || yy < 0 || yy >= height) return;
    const idx = (yy * width + xx) * 3;
    buf[idx] += er * factor;
    buf[idx + 1] += eg * factor;
    buf[idx + 2] += eb * factor;
  };
  add(x + 1, y, 7 / 16);
  add(x - 1, y + 1, 3 / 16);
  add(x, y + 1, 5 / 16);
  add(x + 1, y + 1, 1 / 16);
}

// Floyd-Steinberg dithering down to the 4-color dots palette. Returns a
// flat array of palette indices (0=off, 1=red, 2=green, 3=yellow), one per
// pixel, row-major - same layout the wire format and the preview canvas
// both want.
function ditherToDots(imageData, width, height) {
  const buf = new Float32Array(width * height * 3);
  for (let i = 0; i < width * height; i++) {
    buf[i * 3] = imageData.data[i * 4];
    buf[i * 3 + 1] = imageData.data[i * 4 + 1];
    buf[i * 3 + 2] = imageData.data[i * 4 + 2];
  }

  const codes = new Uint8Array(width * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const idx = y * width + x;
      const r = buf[idx * 3];
      const g = buf[idx * 3 + 1];
      const b = buf[idx * 3 + 2];
      const code = nearestDotsColorIndex(r, g, b);
      codes[idx] = code;
      const [pr, pg, pb] = DOTS_PALETTE[DOTS_ORDER[code]];
      distributeError(buf, width, height, x, y, r - pr, g - pg, b - pb);
    }
  }
  return codes;
}

function clampInt(value, min, max) {
  const n = Number.parseInt(value, 10);
  if (Number.isNaN(n)) return min;
  return Math.min(max, Math.max(min, n));
}

function processImage() {
  if (!loadedImage) return;

  const targetW = clampInt(document.getElementById("image-width").value, 1, 255);
  const targetH = clampInt(document.getElementById("image-height").value, 1, 32);

  const work = document.createElement("canvas");
  work.width = targetW;
  work.height = targetH;
  const ctx = work.getContext("2d");
  ctx.fillStyle = "black";
  ctx.fillRect(0, 0, targetW, targetH);

  // Fit within the target box, preserving aspect ratio, centered - rather
  // than stretching/distorting the source image to an arbitrary size.
  const scale = Math.min(targetW / loadedImage.width, targetH / loadedImage.height);
  const drawW = loadedImage.width * scale;
  const drawH = loadedImage.height * scale;
  ctx.drawImage(loadedImage, (targetW - drawW) / 2, (targetH - drawH) / 2, drawW, drawH);

  const imageData = ctx.getImageData(0, 0, targetW, targetH);
  const codes = ditherToDots(imageData, targetW, targetH);

  state.imageGrid = { width: targetW, height: targetH, pixels: Array.from(codes).join("") };
  renderImagePreview(codes, targetW, targetH);
  updateChipFraction(codes);
  document.getElementById("image-force-btn").hidden = true;
  document.getElementById("image-error").textContent = "";
}

function renderImagePreview(codes, width, height) {
  const canvas = document.getElementById("image-preview-canvas");
  const cellSize = Math.max(2, Math.min(12, Math.floor(400 / width)));
  canvas.width = width * cellSize;
  canvas.height = height * cellSize;
  const ctx = canvas.getContext("2d");
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      ctx.fillStyle = DOTS_PREVIEW_COLORS[codes[y * width + x]];
      ctx.fillRect(x * cellSize, y * cellSize, cellSize, cellSize);
    }
  }
}

// Mirrors AlphaSign::DotsFile#lit_chip_fraction (yellow = 2 chips, red/green
// = 1, off = 0) so the 50% LED safety warning shows before the user even
// hits Send, not just after serial_api rejects it.
function updateChipFraction(codes) {
  let chips = 0;
  codes.forEach((c) => { chips += c === 3 ? 2 : c === 0 ? 0 : 1; });
  const fraction = chips / (codes.length * 2);
  state.imageChipFraction = fraction;

  const el = document.getElementById("image-chip-fraction");
  el.textContent = `Estimated LED chip load: ${Math.round(fraction * 100)}%${fraction > 0.5 ? " - exceeds the sign's 50% safety limit" : ""}`;
  el.className = fraction > 0.5 ? "chip-warning" : "chip-ok";
}

document.getElementById("image-file").addEventListener("change", (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const img = new Image();
    img.onload = () => {
      loadedImage = img;
      processImage();
    };
    img.src = reader.result;
  };
  reader.readAsDataURL(file);
});

document.getElementById("image-width").addEventListener("change", processImage);
document.getElementById("image-height").addEventListener("change", processImage);

async function sendImage(dryRun, force) {
  const errorEl = document.getElementById("image-error");
  errorEl.textContent = "";
  if (!state.imageGrid) {
    errorEl.textContent = "Choose an image first.";
    return;
  }

  const payload = {
    label: document.getElementById("image-label").value,
    width: state.imageGrid.width,
    height: state.imageGrid.height,
    pixels: state.imageGrid.pixels,
    keep_text_labels: document.getElementById("image-keep-text").checked,
    dry_run: dryRun,
    force: !!force
  };

  const { ok, status, body } = await fetchJSON("/api/image", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });

  const forceBtn = document.getElementById("image-force-btn");
  if (!ok) {
    errorEl.textContent = body.error || "Request failed";
    forceBtn.hidden = status !== 422; // only the LED-safety block is meant to be overridable
    return;
  }
  forceBtn.hidden = true;

  const pre = document.getElementById("image-bytes-preview");
  pre.hidden = false;
  pre.textContent = `memory config: ${body.memory_config_bytes_hex}\ndots data:    ${body.dots_bytes_hex}`;

  if (!dryRun) {
    await refreshMessages();
    await refreshStatus();
  }
}

document.getElementById("image-preview-btn").addEventListener("click", () => sendImage(true));
document.getElementById("image-send-btn").addEventListener("click", () => sendImage(false));
document.getElementById("image-force-btn").addEventListener("click", () => sendImage(false, true));

// --- Init ---

(async function init() {
  await loadOptions();
  await refreshStatus();
  await refreshMessages();
  setInterval(refreshStatus, 15000);
})();
