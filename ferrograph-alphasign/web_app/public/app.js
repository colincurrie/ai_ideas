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
  const { body } = await fetchJSON("/api/options");
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
}

async function refreshStatus() {
  const { body } = await fetchJSON("/api/status");
  const dot = document.getElementById("status-dot");
  const text = document.getElementById("status-text");
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
    const preview = (msg.runs || []).map((r) => r.text).join("");

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

    const editBtn = document.createElement("button");
    editBtn.type = "button";
    editBtn.textContent = "Edit";
    editBtn.addEventListener("click", () => loadMessageIntoEditor(label, msg));
    btns.appendChild(editBtn);

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

// --- Init ---

(async function init() {
  await loadOptions();
  await refreshStatus();
  await refreshMessages();
  setInterval(refreshStatus, 15000);
})();
