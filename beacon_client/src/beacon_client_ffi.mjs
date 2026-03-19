// Beacon Client Runtime — the ONLY JavaScript that runs in the browser.
// Event delegation, WebSocket, DOM morphing, Rendered format — all here.
// When BeaconApp is available (compiled user code), runs updates LOCALLY.
// Local-only events produce ZERO WebSocket traffic.

import { Ok, Error as GleamError } from "./gleam.mjs";
import { diffModels, applyOps } from "./beacon_client/patch.mjs";

// === State ===
const _pd = {};
let ws = null;
let heartbeatTimer = null;
let reconnectAttempts = 0;
let appRoot = null;
let hydrated = false;
let eventClock = 0;

// === Client-Side Event Rate Limiting ===
let eventSendCount = 0;
let eventSendWindowStart = 0;
const MAX_EVENTS_PER_SECOND = 30;

function isEventRateLimited() {
  const now = Date.now();
  if (now - eventSendWindowStart > 1000) {
    eventSendCount = 0;
    eventSendWindowStart = now;
  }
  eventSendCount++;
  return eventSendCount > MAX_EVENTS_PER_SECOND;
}

// === Client-Side State (when BeaconApp is available) ===
let clientModel = null;
let clientLocal = null;
let clientRegistry = null;
let clientInitialized = false;
let renderPending = false;  // RAF throttle: true when a render is scheduled
let clientModelJson = null;  // Cached JSON representation for patch diffing

// === Process Dictionary (handler registry storage) ===
export function pd_set(key, value) { _pd[key] = value; return undefined; }
export function pd_get(key) {
  return key in _pd ? new Ok(_pd[key]) : new GleamError(undefined);
}

// === Client-Side Execution ===
export function initClient() {
  // State-over-the-wire: client waits for model_sync from server to initialize.
  // The real model comes from the server — we don't use the stub init().
  // handleModelSync will set clientModel, clientLocal, and clientInitialized.
  if (!window.BeaconApp) return;
  console.log("[beacon] BeaconApp loaded, waiting for model_sync...");
}

function clientRenderNow() {
  if (!clientInitialized || !appRoot) return;
  const App = window.BeaconApp;
  const t0 = performance.now();
  App.start_render();
  const html = App.view_to_html(clientModel, clientLocal);
  clientRegistry = App.finish_render();
  const t1 = performance.now();
  morphInnerHTML(appRoot, html);
  const t2 = performance.now();
  attachEvents();
  renderPending = false;
  // Log slow renders (>5ms)
  const total = t2 - t0;
  if (total > 5) {
    console.log("[beacon] Slow render: view=" + (t1-t0).toFixed(1) + "ms morph=" + (t2-t1).toFixed(1) + "ms total=" + total.toFixed(1) + "ms");
  }
  window._lastRenderMs = total;
}

// Throttled render — batches multiple LOCAL events into one render per frame.
// State is updated immediately (clientModel/clientLocal always current),
// but DOM rendering is deferred to the next animation frame.
function clientRender() {
  if (renderPending) return;  // Already scheduled
  renderPending = true;
  requestAnimationFrame(clientRenderNow);
}

// Synchronous render — used when we need the DOM up-to-date immediately
// (e.g., before sending a MODEL event to the server).
function clientRenderFlush() {
  if (renderPending) {
    renderPending = false;
    clientRenderNow();
  }
}

// Handles an event locally. Returns:
// {action: "local"} — LOCAL event, handled client-only, don't send to server
// {action: "send", ops: ""} — MODEL event, send to server with no ops (no encoder)
// {action: "send", ops: "..."} — MODEL event, send ops (JSON-encoded patch array)
function handleEventLocally(handlerId, eventData, eventName, targetPath, clock) {
  if (!clientInitialized) return { action: "send", ops: "" };
  const App = window.BeaconApp;

  // If update isn't available on client (impure app), send everything to server
  if (!App.update || !App.msg_affects_model) return { action: "send", ops: "" };

  const result = App.resolve_handler(clientRegistry, handlerId, eventData);
  if (!result.isOk()) return { action: "send", ops: "" };

  try {
    const msg = result[0];
    // Snapshot model JSON before update (for diffing)
    const oldModelJson = clientModelJson;

    const updateResult = App.update(clientModel, clientLocal, msg);
    clientModel = updateResult[0];
    clientLocal = updateResult[1];
    clientRender();

    if (App.msg_affects_model(msg)) {
      // MODEL event — applied optimistically, now diff and send ops
      let ops = "";
      if (oldModelJson && App.encode_model) {
        try {
          // encode_model takes (model, local) to match server's model_sync format
          const newModelJsonStr = App.encode_model(clientModel, clientLocal);
          const newModelJson = JSON.parse(newModelJsonStr);
          const patchOps = diffModels(oldModelJson, newModelJson);
          if (patchOps.length > 0) {
            ops = JSON.stringify(patchOps);
          }
          // Update cached JSON for future diffs
          clientModelJson = newModelJson;
        } catch (e) {
          console.warn("[beacon] Model diff failed, sending without ops:", e.message);
          ops = "";
        }
      }
      return { action: "send", ops };
    } else {
      // LOCAL event — client-only, zero server traffic
      return { action: "local" };
    }
  } catch (e) {
    console.error("[beacon] Local update crashed — disabling client execution. All events will go to server.", e);
    clientInitialized = false;
    return { action: "send", ops: "" };
  }
}

// === Initialization ===
export function boot(rootSelector) {
  appRoot = document.querySelector(rootSelector || "#beacon-app");
  if (!appRoot) { console.error("[beacon] Root not found:", rootSelector); return undefined; }
  hydrated = appRoot.childNodes.length > 0;
  if (hydrated) attachEvents();
  const wsUrl = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws";
  connect(wsUrl);
  return undefined;
}

// === WebSocket ===
function connect(wsUrl) {
  ws = new WebSocket(wsUrl);
  ws.onopen = () => {
    reconnectAttempts = 0;
    startHeartbeat();
    const token = appRoot ? appRoot.getAttribute("data-beacon-token") || "" : "";
    send({ type: "join", token, path: location.pathname + location.search });
  };
  ws.onmessage = (e) => handleMessage(e.data);
  ws.onclose = () => { stopHeartbeat(); scheduleReconnect(wsUrl); };
  ws.onerror = (e) => console.error("[beacon] WS error:", e);
}

function send(msg) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg)); }
// Debug: expose WS state for testing
window.__beaconWsState = () => ws ? ws.readyState : -1;
function startHeartbeat() { stopHeartbeat(); heartbeatTimer = setInterval(() => send({ type: "heartbeat" }), 30000); }
function stopHeartbeat() { if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; } }
function scheduleReconnect(wsUrl) {
  const delay = Math.min(1000 * Math.pow(2, reconnectAttempts), 30000);
  const jitter = Math.floor(Math.random() * 1000);
  reconnectAttempts++;
  setTimeout(() => connect(wsUrl), delay + jitter);
}

export function ws_send(data) { send(JSON.parse(data)); return undefined; }
export function ws_connect(url) { connect(url); return undefined; }

// === Message Handling ===
function handleMessage(raw) {
  let msg;
  // Intentional early return on parse failure: malformed messages from the server
  // cannot be processed. We log the error and discard the message rather than
  // crashing the entire client runtime. This is acceptable because a single
  // corrupt frame should not take down the WS connection.
  try { msg = JSON.parse(raw); } catch (e) { console.error("[beacon] Failed to parse server message:", e.message, raw.substring(0, 100)); return; }
  switch (msg.type) {
    case "mount": handleMount(msg.payload); break;
    case "model_sync": handleModelSync(msg.model, msg.version); break;
    case "patch": handlePatch(msg.ops, msg.version); break;
    case "navigate": handleServerNavigate(msg.path); break;
    case "reload": console.log("[beacon] Hot reload — refreshing..."); location.reload(); break;
    case "heartbeat_ack": break;
    case "error": console.error("[beacon] Server error:", msg.reason); break;
  }
}

function handleMount(payload) {
  if (!appRoot) return;
  if (hydrated) {
    // SSR content already in DOM — just attach events and wait for model_sync
    hydrated = false;
    attachEvents();
    return;
  }
  // Plain HTML from server — morph into DOM
  morphInnerHTML(appRoot, payload);
  attachEvents();
}

function handleModelSync(modelJson, version) {
  if (!window.BeaconApp) return;
  const App = window.BeaconApp;
  if (!App.decode_model) return;

  try {
    const result = App.decode_model(modelJson);
    if (result.isOk()) {
      clientModel = result[0];

      // Cache JSON representation for future patch diffing
      try { clientModelJson = JSON.parse(modelJson); } catch (e) { console.error("[beacon] Failed to parse cached model JSON:", e.message); clientModelJson = null; }

      // Decode Local state if available
      if (App.decode_local) {
        const localResult = App.decode_local(modelJson);
        if (localResult.isOk()) {
          clientLocal = localResult[0];
        }
      }

      // Initialize client-side execution on first model_sync if not already done
      if (!clientInitialized) {
        if (!clientLocal && App.init_local) {
          clientLocal = App.init_local(clientModel);
        }
        if (!clientLocal) clientLocal = null;
        clientInitialized = true;
        console.log("[beacon] Client-side execution ready (from model_sync)");
      }

      // Use synchronous render to ensure DOM updates immediately
      // (requestAnimationFrame may not fire in background tabs)
      clientRenderNow();
      console.log("[beacon] Model synced v" + version);
    }
  } catch (e) {
    console.error("[beacon] Model sync decode failed:", e);
  }
}

function handlePatch(opsJson, version) {
  if (!window.BeaconApp) return;
  const App = window.BeaconApp;
  if (!App.decode_model || !clientModelJson) {
    // No cached model to patch — request full sync
    console.warn("[beacon] Patch received but no cached model, ignoring");
    return;
  }

  try {
    // Parse the ops (server sends them as a JSON string)
    const ops = typeof opsJson === "string" ? JSON.parse(opsJson) : opsJson;
    if (!Array.isArray(ops) || ops.length === 0) return;

    // Apply patch operations to cached JSON model
    const newModelJson = applyOps(clientModelJson, ops);
    clientModelJson = newModelJson;

    // Re-encode to string and decode to Gleam model
    const newModelStr = JSON.stringify(newModelJson);
    const result = App.decode_model(newModelStr);
    if (result.isOk()) {
      clientModel = result[0];

      // Decode Local state if available
      if (App.decode_local) {
        const localResult = App.decode_local(newModelStr);
        if (localResult.isOk()) {
          clientLocal = localResult[0];
        }
      }

      clientRenderNow();
      console.log("[beacon] Patch applied v" + version + " (" + ops.length + " ops)");
    } else {
      console.error("[beacon] Patch decode failed, requesting full sync");
      clientModelJson = null;
    }
  } catch (e) {
    console.error("[beacon] Patch apply failed:", e);
    clientModelJson = null;
  }
}

function handleServerNavigate(path) {
  if (path && path !== location.pathname + location.search) {
    history.pushState(null, "", path);
    // Trigger navigate to server for route-change processing
    send({ type: "navigate", path: path });
  }
}

// === Rendered Format ===

// === DOM Morphing ===
export function morph_html(container, html) { morphInnerHTML(container, html); return undefined; }

function morphInnerHTML(container, html) {
  // Save focused element state before morphing
  const focused = document.activeElement;
  const focusedTag = focused?.tagName;
  const focusedName = focused?.getAttribute("name") || focused?.getAttribute("data-beacon-event-input");
  const selStart = focused?.selectionStart;
  const selEnd = focused?.selectionEnd;
  const focusedValue = focused?.value;

  const t = document.createElement("template"); t.innerHTML = html; morphChildren(container, t.content);

  // Restore focus after morph — find the same element by name/handler
  if (focusedTag === "INPUT" || focusedTag === "TEXTAREA" || focusedTag === "SELECT") {
    let restored = null;
    if (focusedName) {
      restored = container.querySelector(`[name="${focusedName}"]`) ||
                 container.querySelector(`[data-beacon-event-input="${focusedName}"]`);
    }
    if (!restored && focused.type) {
      // Fallback: find by type and placeholder
      const placeholder = focused.getAttribute("placeholder");
      if (placeholder) {
        restored = container.querySelector(`${focusedTag}[placeholder="${placeholder}"]`);
      }
    }
    if (restored && restored !== document.activeElement) {
      restored.focus();
      // Restore cursor position
      if (typeof selStart === "number" && restored.setSelectionRange) {
        try { restored.setSelectionRange(selStart, selEnd); } catch(e) { console.warn("[beacon] setSelectionRange failed:", e.message); }
      }
      // Restore value if morph overwrote it (server might be behind client)
      if (focusedValue !== undefined && restored.value !== focusedValue) {
        restored.value = focusedValue;
      }
    }
  }
}

function morphChildren(op, np) {
  let oc = op.firstChild, nc = np.firstChild;
  while (nc) {
    if (!oc) { op.appendChild(nc.cloneNode(true)); nc = nc.nextSibling; continue; }
    if (sameNode(oc, nc)) { morphNode(oc, nc); oc = oc.nextSibling; nc = nc.nextSibling; continue; }
    const m = findMatch(oc.nextSibling, nc);
    if (m) { while (oc && oc !== m) { const nx = oc.nextSibling; op.removeChild(oc); oc = nx; } if (oc) { morphNode(oc, nc); oc = oc.nextSibling; } nc = nc.nextSibling; continue; }
    op.insertBefore(nc.cloneNode(true), oc); nc = nc.nextSibling;
  }
  while (oc) { const nx = oc.nextSibling; op.removeChild(oc); oc = nx; }
}

function morphNode(o, n) {
  if (o.nodeType === 3) { if (o.textContent !== n.textContent) o.textContent = n.textContent; return; }
  if (o.nodeType !== 1) return;
  morphAttributes(o, n);
  if ((o.tagName === "INPUT" || o.tagName === "TEXTAREA" || o.tagName === "SELECT") && o === document.activeElement) return;
  morphChildren(o, n);
}

function morphAttributes(o, n) {
  for (let i = o.attributes.length - 1; i >= 0; i--) if (!n.hasAttribute(o.attributes[i].name)) o.removeAttribute(o.attributes[i].name);
  for (let i = 0; i < n.attributes.length; i++) { const nm = n.attributes[i].name, v = n.attributes[i].value; if (o.getAttribute(nm) !== v) o.setAttribute(nm, v); }
}

function sameNode(a, b) { if (a.nodeType !== b.nodeType) return false; if (a.nodeType === 3) return true; if (a.nodeType !== 1) return false; if (a.tagName !== b.tagName) return false; if (a.id && b.id) return a.id === b.id; return true; }
function findMatch(s, t) { let c = s, k = 5; while (c && k > 0) { if (sameNode(c, t)) return c; c = c.nextSibling; k--; } return null; }

// === Event Delegation ===

// Helper: dispatch an event through local handling and/or server.
// Builds the wire message with optional ops for patch-based sync.
function dispatchEvent(eventName, hid, data, tp) {
  eventClock++;
  if (clientInitialized) {
    const r = handleEventLocally(hid, data, eventName, tp, eventClock);
    if (r.action === "send") {
      if (isEventRateLimited()) {
        console.warn("[beacon] Event rate limited (>" + MAX_EVENTS_PER_SECOND + "/s)");
        return;
      }
      const msg = { type: "event", name: eventName, handler_id: hid, data, target_path: tp, clock: eventClock };
      if (r.ops) msg.ops = r.ops;
      send(msg);
    }
  } else {
    if (isEventRateLimited()) {
      console.warn("[beacon] Event rate limited (>" + MAX_EVENTS_PER_SECOND + "/s)");
      return;
    }
    send({ type: "event", name: eventName, handler_id: hid, data, target_path: tp, clock: eventClock });
  }
}

function attachEvents() {
  if (!appRoot) return;
  appRoot.onclick = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-click")) {
        e.preventDefault();
        dispatchEvent("click", t.getAttribute("data-beacon-event-click"), "{}", getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.oninput = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-input")) {
        const hid = t.getAttribute("data-beacon-event-input");
        const data = JSON.stringify({ value: t.value || "" });
        dispatchEvent("input", hid, data, getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onsubmit = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-submit")) {
        e.preventDefault();
        dispatchEvent("submit", t.getAttribute("data-beacon-event-submit"), "{}", getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmousedown = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mousedown")) {
        const hid = t.getAttribute("data-beacon-event-mousedown");
        const rect = t.getBoundingClientRect();
        const x = Math.round(e.clientX - rect.left);
        const y = Math.round(e.clientY - rect.top);
        dispatchEvent("mousedown", hid, JSON.stringify({ value: x + "," + y }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmouseup = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mouseup")) {
        dispatchEvent("mouseup", t.getAttribute("data-beacon-event-mouseup"), "{}", getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmousemove = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mousemove")) {
        const hid = t.getAttribute("data-beacon-event-mousemove");
        const rect = t.getBoundingClientRect();
        const x = Math.round(e.clientX - rect.left);
        const y = Math.round(e.clientY - rect.top);
        dispatchEvent("mousemove", hid, JSON.stringify({ value: x + "," + y }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.ondragstart = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-dragstart")) {
        const hid = t.getAttribute("data-beacon-event-dragstart");
        const dragId = t.getAttribute("data-drag-id") || "";
        e.dataTransfer.setData("text/plain", dragId);
        e.dataTransfer.effectAllowed = "move";
        setTimeout(() => { t.style.opacity = "0.4"; }, 0);
        dispatchEvent("dragstart", hid, JSON.stringify({ value: dragId }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.ondragend = (e) => {
    // Reset opacity on all draggable elements
    appRoot.querySelectorAll("[draggable]").forEach(el => { el.style.opacity = "1"; });
  };
  appRoot.ondragover = (e) => {
    // Walk up from target to find a drop zone (has data-beacon-event-drop)
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-drop")) {
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
        t.style.outline = "2px dashed #2196F3";
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.ondragleave = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-drop")) {
        // Only remove highlight if we're leaving the drop zone itself,
        // not when entering a child element
        if (!t.contains(e.relatedTarget)) {
          t.style.outline = "";
        }
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.ondrop = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-drop")) {
        e.preventDefault();
        t.style.outline = "";
        const dragId = e.dataTransfer.getData("text/plain");
        dispatchEvent("drop", t.getAttribute("data-beacon-event-drop"), JSON.stringify({ value: dragId }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onkeydown = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-keydown")) {
        dispatchEvent("keydown", t.getAttribute("data-beacon-event-keydown"), JSON.stringify({ value: e.key }), getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
}

function getPath(node) {
  const parts = []; let c = node;
  while (c && c !== appRoot) { const p = c.parentNode; if (p) { const ch = p.childNodes; for (let i = 0; i < ch.length; i++) if (ch[i] === c) { parts.unshift(i); break; } } c = c.parentNode; }
  return parts.join(".");
}

// === SPA Navigation ===
function setupNavigation() {
  // Intercept internal link clicks for SPA navigation
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[href]");
    if (!a) return;
    // Only intercept same-origin links without data-beacon-external
    if (a.hostname !== location.hostname) return;
    if (a.hasAttribute("data-beacon-external")) return;
    if (a.target === "_blank") return;

    e.preventDefault();
    const path = a.pathname + a.search;
    if (path !== location.pathname + location.search) {
      history.pushState(null, "", path);
      send({ type: "navigate", path: path });
    }
  });

  // Handle browser back/forward
  window.addEventListener("popstate", () => {
    send({ type: "navigate", path: location.pathname + location.search });
  });
}

// === Exports for Gleam FFI ===
export function query_selector(sel) { const el = document.querySelector(sel); return el ? { type: "Ok", 0: el } : { type: "Error", 0: undefined }; }
export function log(msg) { console.log("[beacon]", msg); return undefined; }

// === Auto-boot ===
if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => { boot("#beacon-app"); setupNavigation(); });
  else { boot("#beacon-app"); setupNavigation(); }
}

// Called from bundle entry AFTER window.BeaconApp is set
export function initClientAfterBoot() {
  // If boot hasn't run yet (script loaded before DOMContentLoaded),
  // defer initClient to after boot
  if (!appRoot) {
    document.addEventListener("DOMContentLoaded", () => initClient());
  } else {
    initClient();
  }
}
