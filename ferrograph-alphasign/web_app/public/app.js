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

// Renders a write response's packets. A reconfiguration is worth calling
// out: it's the one operation that blanks the display and re-sends every
// file, so it shouldn't happen silently.
function showBytes(id, body) {
  const pre = document.getElementById(id);
  pre.hidden = false;
  const lines = [];
  if (body && body.reconfigured) {
    lines.push("memory reconfigured (display blanks briefly; all files re-sent)");
    if (body.memory_config_bytes_hex) lines.push(`memory config: ${body.memory_config_bytes_hex}`);
  }
  const packets = Array.isArray(body?.bytes_hex) ? body.bytes_hex : [body?.bytes_hex].filter(Boolean);
  packets.forEach((hex, i) => lines.push(packets.length > 1 ? `packet ${i + 1}: ${hex}` : hex));
  pre.textContent = lines.join("\n") || "(no packets)";
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

  // String labels are conventionally digits, keeping them clear of the
  // letters used for text and picture files - nothing in the protocol
  // requires it, it just makes a layout easier to read.
  const stringLabelSelect = document.getElementById("string-label");
  stringLabelSelect.innerHTML = "";
  "123456789".split("").forEach((digit) => {
    const opt = document.createElement("option");
    opt.value = digit;
    opt.textContent = digit;
    stringLabelSelect.appendChild(opt);
  });
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

// Renders every file the sign is holding, across all three types, and
// keeps the "insert into message" dropdowns in sync with what actually
// exists to be referenced.
async function refreshMessages() {
  const { body } = await fetchJSON("/api/files");
  const list = document.getElementById("labels-list");
  const empty = document.getElementById("labels-empty");
  const text = body.text || {};
  const strings = body.strings || {};
  const dots = body.dots || {};

  state.files = body;
  list.innerHTML = "";
  const total = Object.keys(text).length + Object.keys(strings).length + Object.keys(dots).length;
  empty.hidden = total > 0;

  const row = (label, kind, preview, onEdit) => {
    const li = document.createElement("li");

    const contentSpan = document.createElement("span");
    contentSpan.className = "content";
    const tag = document.createElement("span");
    tag.className = "label-tag";
    tag.textContent = `${kind} ${label}`;
    contentSpan.appendChild(tag);
    contentSpan.appendChild(document.createTextNode(preview));
    li.appendChild(contentSpan);

    const btns = document.createElement("span");
    btns.className = "btns";
    if (onEdit) {
      const editBtn = document.createElement("button");
      editBtn.type = "button";
      editBtn.textContent = "Edit";
      editBtn.addEventListener("click", onEdit);
      btns.appendChild(editBtn);
    }
    const clearBtn = document.createElement("button");
    clearBtn.type = "button";
    clearBtn.className = "danger";
    clearBtn.textContent = "Clear";
    clearBtn.addEventListener("click", () => clearFile(kind, label));
    btns.appendChild(clearBtn);

    li.appendChild(btns);
    list.appendChild(li);
  };

  Object.keys(text).sort().forEach((label) => {
    const msg = text[label];
    const preview = (msg.runs || [])
      .map((r) => (r.type ? `[${r.type} ${r.label}]` : r.text))
      .join("");
    row(label, "text", preview, () => loadMessageIntoEditor(label, msg));
  });
  Object.keys(strings).sort().forEach((label) => {
    row(label, "string", strings[label].text, () => {
      document.getElementById("string-label").value = label;
      document.getElementById("string-text").value = strings[label].text;
    });
  });
  Object.keys(dots).sort().forEach((label) => {
    row(label, "image", `${dots[label].width}×${dots[label].height}`, null);
  });

  populateReferenceSelect("insert-image-select", Object.keys(dots).sort(), "(save an image first)");
  populateReferenceSelect("insert-string-select", Object.keys(strings).sort(), "(save a string first)");
  refreshImageInsertButton();
}

function populateReferenceSelect(id, labels, emptyLabel) {
  const select = document.getElementById(id);
  const previous = select.value;
  select.innerHTML = "";
  if (labels.length === 0) {
    const opt = document.createElement("option");
    opt.value = "";
    // Only files that already exist on the sign can be referenced, so an
    // empty list means "go and save one", not "this feature is broken".
    opt.textContent = emptyLabel || "(none yet)";
    select.appendChild(opt);
    return;
  }
  labels.forEach((label) => {
    const opt = document.createElement("option");
    opt.value = label;
    opt.textContent = label;
    select.appendChild(opt);
  });
  if (labels.includes(previous)) select.value = previous;
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
    if (run.type) {
      const chip = document.createElement("span");
      chip.className = "ref-chip";
      chip.dataset.refType = run.type;
      chip.dataset.refLabel = run.label;
      chip.contentEditable = "false";
      chip.textContent = run.type === "image" ? `\u{1F5BC} ${run.label}` : `\u{1F524} ${run.label}`;
      editor.appendChild(chip);
    } else if (run.color || run.font) {
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

// Walks the editor's DOM, turning it into the flat run list the API
// expects. Styled <span data-color data-font> subtrees become {text,
// color, font} runs - a span's formatting applies to its whole subtree
// unless a nested span overrides it, matching how the wire protocol's
// control codes persist until changed. Reference chips
// (<span data-ref-type data-ref-label>) become {type, label} runs, which
// encode as a call to another file rather than as literal text.
function serializeEditor() {
  const runs = [];
  function walk(node, color, font) {
    if (node.nodeType === Node.TEXT_NODE) {
      // contenteditable inserts non-breaking spaces to stop runs of
      // spaces collapsing; the sign has no glyph for one, so send the
      // plain space that was actually meant.
      const text = node.textContent.replace(/\u00a0/g, " ");
      if (text.length) runs.push({ text, color, font });
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;

    if (node.dataset && node.dataset.refType) {
      runs.push({ type: node.dataset.refType, label: node.dataset.refLabel });
      return; // the chip's visible caption is decoration, not message text
    }

    const c = (node.dataset && node.dataset.color) || color;
    const f = (node.dataset && node.dataset.font) || font;
    node.childNodes.forEach((child) => walk(child, c, f));
  }
  document.getElementById("editor").childNodes.forEach((n) => walk(n, null, null));
  return runs;
}

// --- Inserting references to other files ---

function insertReferenceChip(refType, label) {
  const editor = document.getElementById("editor");
  const chip = document.createElement("span");
  chip.className = "ref-chip";
  chip.dataset.refType = refType;
  chip.dataset.refLabel = label;
  chip.contentEditable = "false";
  chip.textContent = refType === "image" ? `\u{1F5BC} ${label}` : `\u{1F524} ${label}`;
  chip.title = `Calls ${refType} file ${label} at this point in the message`;

  const sel = window.getSelection();
  if (sel.rangeCount && editor.contains(sel.getRangeAt(0).commonAncestorContainer)) {
    const range = sel.getRangeAt(0);
    range.deleteContents();
    range.insertNode(chip);
    range.setStartAfter(chip);
    range.collapse(true);
    sel.removeAllRanges();
    sel.addRange(range);
  } else {
    editor.appendChild(chip); // nothing focused - just append
  }
  editor.focus();
}

document.getElementById("insert-image-btn").addEventListener("click", () => {
  const label = document.getElementById("insert-image-select").value;
  if (!label) {
    flashError("Upload an image first - then you can insert it into a message.");
    return;
  }
  clearError();
  insertReferenceChip("image", label);
});

document.getElementById("insert-string-btn").addEventListener("click", () => {
  const label = document.getElementById("insert-string-select").value;
  if (!label) {
    flashError("Save a string first - then you can insert it into a message.");
    return;
  }
  clearError();
  insertReferenceChip("string", label);
});

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
  showBytes("bytes-preview", body);
  if (!dryRun) {
    await refreshMessages();
    await refreshStatus();
  }
}

const CLEAR_PATHS = { text: "/api/messages", string: "/api/strings", image: "/api/image" };

async function clearFile(kind, label) {
  clearError();
  const base = CLEAR_PATHS[kind] || CLEAR_PATHS.text;
  const { ok, body } = await fetchJSON(`${base}/${encodeURIComponent(label)}`, { method: "DELETE" });
  if (!ok) {
    flashError(body.error || "Request failed");
    return;
  }
  showBytes("bytes-preview", body);
  await refreshMessages();
  await refreshStatus();
}

document.getElementById("preview-btn").addEventListener("click", () => sendMessage(true));
document.getElementById("send-btn").addEventListener("click", () => sendMessage(false));
document.getElementById("clear-btn").addEventListener("click", () => clearFile("text", document.getElementById("label").value));

// --- Strings ---

async function sendString(dryRun) {
  const errorEl = document.getElementById("string-error");
  errorEl.textContent = "";
  const payload = {
    label: document.getElementById("string-label").value,
    text: document.getElementById("string-text").value,
    dry_run: dryRun
  };
  const { ok, body } = await fetchJSON("/api/strings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (!ok) {
    errorEl.textContent = body.error || "Request failed";
    return;
  }
  showBytes("string-bytes-preview", body);
  if (!dryRun) {
    await refreshMessages();
    await refreshStatus();
  }
}

document.getElementById("string-preview-btn").addEventListener("click", () => sendString(true));
document.getElementById("string-send-btn").addEventListener("click", () => sendString(false));

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
// The picture logic itself lives in pixel_grid.js (loaded first, and
// covered by test/web_app/pixel_grid_test.js); what's left here is the DOM
// wiring around it.
const {
  PREVIEW_COLORS, SIGN_WIDTH, SIGN_HEIGHT, clampInt, ditherToDots,
  naturalTargetSize, encodePixels, decodePixels, resizeCodes, paintLine,
  chipFraction, fitCellSize
} = PixelGrid;

let loadedImage = null;

// --- The pixel grid ---
//
// There is exactly one grid (state.imageGrid), and both ways of making a
// picture write to it: uploading replaces it wholesale, the drawing editor
// edits it in place. That's deliberate - it means you can upload something
// roughly right and then fix the handful of pixels the dither got wrong,
// rather than having to get it perfect outside the app first.

function gridCodes() {
  return state.imageGrid ? decodePixels(state.imageGrid.pixels) : null;
}

function setGrid(width, height, codes) {
  state.imageGrid = { width, height, pixels: encodePixels(codes) };
  renderGrid();
  updateChipFraction(codes);
  document.getElementById("image-force-btn").hidden = true;
  document.getElementById("image-error").textContent = "";
}

function blankGrid(width, height) {
  setGrid(width, height, new Uint8Array(width * height));
}

function resizeGrid(width, height) {
  const old = state.imageGrid;
  setGrid(width, height, old ? resizeCodes(gridCodes(), old.width, old.height, width, height)
                             : new Uint8Array(width * height));
}

function gridSizeFromInputs() {
  return {
    width: clampInt(document.getElementById("image-width").value, 1, SIGN_WIDTH),
    height: clampInt(document.getElementById("image-height").value, 1, SIGN_HEIGHT)
  };
}

function drawing() {
  return document.getElementById("image-source").value === "draw";
}

// --- Rendering the grid ---
//
// One canvas serves as both the upload preview and the drawing surface, so
// what you paint on is exactly what gets sent. Cell size is the only
// difference: a 135-wide picture is unpaintable at preview scale, so the
// editor zooms it up and lets the container scroll.

function cellSize(width) {
  const zoom = document.getElementById("draw-zoom").value;
  if (zoom !== "fit") return Number.parseInt(zoom, 10);
  // Measured from the card, not the scroll container: the container is
  // sized to fit its canvas, so measuring it would make "fit width" depend
  // on the number it's trying to produce.
  const card = document.getElementById("image-canvas-scroll").parentElement;
  const style = getComputedStyle(card);
  const available = card.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight) - 2;
  return fitCellSize(available, width);
}

function renderGrid() {
  const grid = state.imageGrid;
  const canvas = document.getElementById("image-preview-canvas");
  if (!grid) {
    canvas.width = 0;
    canvas.height = 0;
    return;
  }

  const codes = gridCodes();
  const size = drawing() ? cellSize(grid.width) : Math.max(2, Math.min(12, Math.floor(400 / grid.width)));
  canvas.width = grid.width * size;
  canvas.height = grid.height * size;
  canvas.classList.toggle("paintable", drawing());

  const ctx = canvas.getContext("2d");
  for (let y = 0; y < grid.height; y++) {
    for (let x = 0; x < grid.width; x++) {
      ctx.fillStyle = PREVIEW_COLORS[codes[y * grid.width + x]];
      ctx.fillRect(x * size, y * size, size, size);
    }
  }

  // Gridlines only when painting, and only when the cells are big enough
  // for them to help rather than smother the picture. Every 8th line is
  // brighter: counting to a pixel column on a 135-wide grid is otherwise
  // hopeless.
  if (!drawing() || size < 5) return;
  ctx.lineWidth = 1;
  for (let x = 0; x <= grid.width; x++) {
    ctx.strokeStyle = x % 8 === 0 ? "rgba(255,255,255,0.35)" : "rgba(255,255,255,0.12)";
    ctx.beginPath();
    ctx.moveTo(x * size + 0.5, 0);
    ctx.lineTo(x * size + 0.5, canvas.height);
    ctx.stroke();
  }
  for (let y = 0; y <= grid.height; y++) {
    ctx.strokeStyle = y % 8 === 0 ? "rgba(255,255,255,0.35)" : "rgba(255,255,255,0.12)";
    ctx.beginPath();
    ctx.moveTo(0, y * size + 0.5);
    ctx.lineTo(canvas.width, y * size + 0.5);
    ctx.stroke();
  }
}

// --- Drawing ---

const UNDO_LIMIT = 60;
let painting = null; // the code being painted for the current stroke
let lastCell = null; // where the stroke was last seen, for joining up a fast drag

function pushUndo() {
  if (!state.imageGrid) return;
  state.drawUndo = state.drawUndo || [];
  state.drawUndo.push({ ...state.imageGrid });
  if (state.drawUndo.length > UNDO_LIMIT) state.drawUndo.shift();
  document.getElementById("draw-undo-btn").disabled = false;
}

function undo() {
  const previous = (state.drawUndo || []).pop();
  if (!previous) return;
  const codes = decodePixels(previous.pixels);
  document.getElementById("image-width").value = previous.width;
  document.getElementById("image-height").value = previous.height;
  setGrid(previous.width, previous.height, codes);
  document.getElementById("draw-undo-btn").disabled = state.drawUndo.length === 0;
}

function selectedPaintCode() {
  const active = document.querySelector("#draw-palette .swatch.active");
  return active ? Number.parseInt(active.dataset.code, 10) : 1;
}

function cellAt(event) {
  const grid = state.imageGrid;
  const canvas = document.getElementById("image-preview-canvas");
  const rect = canvas.getBoundingClientRect();
  const size = rect.width / grid.width; // read from the rect so CSS scaling can't skew it
  const x = Math.floor((event.clientX - rect.left) / size);
  const y = Math.floor((event.clientY - rect.top) / size);
  if (x < 0 || y < 0 || x >= grid.width || y >= grid.height) return null;
  return { x, y };
}

function paintAt(event, code) {
  const cell = cellAt(event);
  if (!cell) return;
  const grid = state.imageGrid;
  const codes = gridCodes();
  const changed = paintLine(codes, grid.width, grid.height, lastCell || cell, cell, code);
  lastCell = cell;
  if (changed) setGrid(grid.width, grid.height, codes);
}

(function wireDrawing() {
  const canvas = document.getElementById("image-preview-canvas");

  canvas.addEventListener("pointerdown", (event) => {
    if (!drawing() || !state.imageGrid) return;
    event.preventDefault();
    // Right-click (or ctrl-click) erases - the same reach-for-the-other-
    // button reflex every pixel editor has.
    painting = event.button === 2 || event.ctrlKey ? 0 : selectedPaintCode();
    lastCell = null; // a new stroke starts where it starts - don't join it to the last one
    // preventDefault above stops the browser moving focus by itself, so
    // move it here: without this, focus stays on whatever select or field
    // was touched last (the zoom dropdown, say) and the 1-4 shortcuts go
    // quietly dead - or worse, retarget that control.
    // preventScroll matters: without it the browser scrolls the canvas into
    // view on the click that starts a stroke, jumping the page out from
    // under the cursor mid-drag.
    canvas.focus({ preventScroll: true });
    pushUndo();
    canvas.setPointerCapture(event.pointerId);
    paintAt(event, painting);
  });

  canvas.addEventListener("pointermove", (event) => {
    if (painting === null) return;
    paintAt(event, painting);
  });

  const stop = () => { painting = null; lastCell = null; };
  canvas.addEventListener("pointerup", stop);
  canvas.addEventListener("pointercancel", stop);
  canvas.addEventListener("contextmenu", (event) => { if (drawing()) event.preventDefault(); });

  document.getElementById("draw-palette").addEventListener("click", (event) => {
    const swatch = event.target.closest(".swatch");
    if (!swatch) return;
    document.querySelectorAll("#draw-palette .swatch").forEach((s) => s.classList.remove("active"));
    swatch.classList.add("active");
  });

  // 1-4 pick a colour, the way every drawing tool does. Ignored while
  // you're typing into the message editor or any other field.
  document.addEventListener("keydown", (event) => {
    if (!drawing()) return;
    const tag = document.activeElement && document.activeElement.tagName;
    if (tag === "INPUT" || tag === "SELECT" || document.activeElement.isContentEditable) return;
    const index = ["1", "2", "3", "4"].indexOf(event.key);
    if (index === -1) return;
    const swatch = document.querySelector(`#draw-palette .swatch[data-code="${index}"]`);
    if (swatch) swatch.click();
  });

  document.getElementById("draw-undo-btn").addEventListener("click", undo);

  document.getElementById("draw-clear-btn").addEventListener("click", () => {
    const { width, height } = gridSizeFromInputs();
    pushUndo();
    blankGrid(width, height);
  });

  document.getElementById("draw-zoom").addEventListener("change", renderGrid);
})();

// --- Uploading ---

function processImage() {
  if (!loadedImage) return;
  const { width: targetW, height: targetH } = gridSizeFromInputs();

  const work = document.createElement("canvas");
  work.width = targetW;
  work.height = targetH;
  const ctx = work.getContext("2d");
  ctx.fillStyle = "black";
  ctx.fillRect(0, 0, targetW, targetH);

  // Fit within the target box preserving aspect ratio, centered - and
  // never scale *up*: enlarging a small source can't add detail, it just
  // smears whole LEDs across what were crisp pixel edges. An icon smaller
  // than the target box is placed at its true size instead.
  const scale = Math.min(targetW / loadedImage.width, targetH / loadedImage.height, 1);
  const drawW = loadedImage.width * scale;
  const drawH = loadedImage.height * scale;
  ctx.imageSmoothingEnabled = scale < 1; // resampling only matters when shrinking
  ctx.drawImage(loadedImage, Math.round((targetW - drawW) / 2), Math.round((targetH - drawH) / 2), drawW, drawH);

  const imageData = ctx.getImageData(0, 0, targetW, targetH);
  const dither = document.getElementById("image-dither").value === "dither";
  pushUndo(); // so switching to Draw and hating the dither isn't a dead end
  setGrid(targetW, targetH, ditherToDots(imageData, targetW, targetH, dither));
}

function updateChipFraction(codes) {
  const fraction = chipFraction(codes);
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
      // Size the target box to the image rather than the other way round,
      // so icons keep their exact dimensions and only oversized artwork is
      // scaled down. Both fields stay editable if you want something else.
      const natural = naturalTargetSize(img.width, img.height);
      document.getElementById("image-width").value = natural.width;
      document.getElementById("image-height").value = natural.height;
      document.getElementById("image-source-size").textContent =
        `Source ${img.width}×${img.height}px${natural.width === img.width && natural.height === img.height ? " - used at full size" : ` - scaled down to fit ${SIGN_WIDTH}×${SIGN_HEIGHT}`}`;
      processImage();
    };
    img.src = reader.result;
  };
  reader.readAsDataURL(file);
});

// --- Switching between the two ---

function applySourceMode() {
  const draw = drawing();
  document.getElementById("image-draw-panel").hidden = !draw;
  document.getElementById("image-upload-panel").hidden = draw;
  document.getElementById("draw-hint").hidden = !draw;
  // Switching to Draw keeps whatever is on the canvas, so an upload can be
  // touched up by hand rather than started again from nothing.
  if (draw && !state.imageGrid) {
    const { width, height } = gridSizeFromInputs();
    blankGrid(width, height);
  } else {
    renderGrid();
  }
}

document.getElementById("image-source").addEventListener("change", applySourceMode);

function onSizeChanged() {
  const { width, height } = gridSizeFromInputs();
  if (drawing()) {
    if (state.imageGrid && (state.imageGrid.width !== width || state.imageGrid.height !== height)) {
      pushUndo();
      resizeGrid(width, height);
    }
  } else {
    processImage();
  }
}

document.getElementById("image-width").addEventListener("change", onSizeChanged);
document.getElementById("image-height").addEventListener("change", onSizeChanged);
document.getElementById("image-dither").addEventListener("change", processImage);
window.addEventListener("resize", () => { if (drawing()) renderGrid(); });

async function sendImage(dryRun, force) {
  const errorEl = document.getElementById("image-error");
  errorEl.textContent = "";
  if (!state.imageGrid) {
    errorEl.textContent = drawing() ? "Draw something first." : "Choose an image first.";
    return;
  }

  const payload = {
    label: document.getElementById("image-label").value,
    width: state.imageGrid.width,
    height: state.imageGrid.height,
    pixels: state.imageGrid.pixels,
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
  showBytes("image-bytes-preview", body);

  if (!dryRun) {
    await refreshMessages();
    await refreshStatus();
    // The picture is only stored, not shown - it appears when a message
    // calls it, so point at the next step rather than leaving the user
    // wondering why the sign didn't change.
    errorEl.textContent = "";
    document.getElementById("image-hint").textContent =
      `Saved as image ${payload.label} - it's on the sign but nothing displays it yet. ` +
      `Use "Insert into message" to put it in a message.`;
  }
}

// An image only becomes referenceable once it's on the sign, so this
// enables itself when the label in the picker is one that's been saved.
// It exists because the two halves of the job sit in different cards:
// without it you save a picture here and then have to go back up to the
// compose card to find it, which reads as a chicken-and-egg (the Insert
// image dropdown can't list an image that doesn't exist yet).
function refreshImageInsertButton() {
  const label = document.getElementById("image-label").value;
  const saved = !!(state.files && state.files.dots && state.files.dots[label]);
  const button = document.getElementById("image-insert-btn");
  button.disabled = !saved;
  button.title = saved ? `Add a call to image ${label} to the message above`
                       : "Save the image to the sign first - a message can only call one that exists";
}

document.getElementById("image-label").addEventListener("change", refreshImageInsertButton);

document.getElementById("image-insert-btn").addEventListener("click", () => {
  const label = document.getElementById("image-label").value;
  insertReferenceChip("image", label);
  document.getElementById("editor").scrollIntoView({ block: "center", behavior: "smooth" });
  document.getElementById("image-hint").textContent =
    `Image ${label} added to the message. Send the message to put it on the display.`;
});

document.getElementById("image-preview-btn").addEventListener("click", () => sendImage(true));
document.getElementById("image-send-btn").addEventListener("click", () => sendImage(false));
document.getElementById("image-force-btn").addEventListener("click", () => sendImage(false, true));

// --- Init ---

(async function init() {
  await loadOptions();
  await refreshStatus();
  await refreshMessages();
  applySourceMode(); // lays out the image card and puts a blank grid up to draw on
  setInterval(refreshStatus, 15000);
})();
