// Beacon Client Runtime — the ONLY JavaScript that runs in the browser.
// Event delegation, WebSocket, DOM morphing, Rendered format — all here.
// When BeaconApp is available (compiled user code), runs updates LOCALLY.
// Local-only events produce ZERO WebSocket traffic.
// Keydown is forwarded for non-text targets, and text inputs/textareas only
// forward Enter without Shift when not composing, so chat composers do not
// flood the server while still supporting submit-by-enter.

import { Ok, Error as GleamError } from "./gleam.mjs";
import { applyOps } from "./beacon_client/patch.mjs";

// === State ===
const _pd = {};
let ws = null;
let heartbeatTimer = null;
let reconnectAttempts = 0;
let appRoot = null;
let hydrated = false;
let eventClock = 0;
let currentModelVersion = 0;
let latestAckClock = 0;
const TRACE_LIMIT = 400;
const traceBuffer = [];
const hookRegistry = new Map();
const mountedHooks = new WeakMap();

// === Client-Side Event Rate Limiting ===
let eventSendCount = 0;
let eventSendWindowStart = 0;
const MAX_EVENTS_PER_SECOND = 30;
const INPUT_DEBOUNCE_MS = 80;
const pendingInputEvents = new Map();

function isDevMode() {
  return !!appRoot && appRoot.getAttribute("data-beacon-dev") === "true";
}

function trace(kind, detail = {}) {
  if (!isDevMode()) return;
  traceBuffer.push({ ts: Date.now(), kind, ...detail });
  if (traceBuffer.length > TRACE_LIMIT) traceBuffer.shift();
}

function ensureBeaconDebug() {
  if (typeof window === "undefined") return;
  window.__beacon = window.__beacon || {};
  window.__beacon.trace = () => traceBuffer.slice();
}

function ensureHookRegistry() {
  if (typeof window === "undefined") return;
  window.beaconClient = window.beaconClient || {};
  window.beaconClient.registerHook = (name, hook) => {
    hookRegistry.set(name, hook);
    trace("hook.register", { name });
  };
}

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
let pendingSendQueue = [];
let readyForServerEvents = false;
let pendingLocalEvents = [];

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
// {action: "send", ops: ""} — MODEL event, server recomputes authoritative state
function handleEventLocally(handlerId, eventData, eventName, targetPath, clock) {
  if (!clientInitialized) return { action: "send", ops: "" };
  const App = window.BeaconApp;

  // If update isn't available on client (impure app), send everything to server
  if (!App.update || !App.msg_affects_model) return { action: "send", ops: "" };

  const result = App.resolve_handler(clientRegistry, handlerId, eventData);
  if (!result.isOk()) return { action: "send", ops: "" };

  try {
    const msg = result[0];

    const updateResult = App.update(clientModel, clientLocal, msg);
    clientModel = updateResult[0];
    clientLocal = updateResult[1];
    clientRender();

    const affectsModel = App.msg_affects_model(msg);
    if (affectsModel) {
      // MODEL event — rendered optimistically on the client, then sent as an
      // event. The server recomputes the authoritative model and returns sync/patch.
      return { action: "send", ops: "" };
    } else if (eventName === "keydown") {
      // Keydown events must still reach the server so server-side apps can
      // respond to Enter / navigation keys even when the local update is
      // model-neutral.
      return { action: "send", ops: "" };
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
  const root = document.querySelector(rootSelector || "#beacon-app");
  if (!root) { console.error("[beacon] Root not found:", rootSelector); return undefined; }
  ensureBeaconDebug();
  ensureHookRegistry();
  setAppRoot(root);
  hydrated = appRoot.childNodes.length > 0;
  if (hydrated) attachEvents();
  const wsUrl = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws";
  connect(wsUrl);
  return undefined;
}

function setAppRoot(root) {
  const previousRoot = appRoot;
  appRoot = root;
  if (!previousRoot) {
    trace("root.init", { root: describeNode(root) });
    return;
  }
  if (previousRoot === root) return;
  trace("root.replace", {
    from: describeNode(previousRoot),
    to: describeNode(root),
  });
  unmountSubtree(previousRoot);
}

// === WebSocket ===
function connect(wsUrl) {
  readyForServerEvents = false;
  ws = new WebSocket(wsUrl);
  ws.onopen = () => {
    reconnectAttempts = 0;
    startHeartbeat();
    sendNow({ type: "join", token: "", path: location.pathname + location.search });
  };
  ws.onmessage = (e) => handleMessage(e.data);
  ws.onclose = () => { stopHeartbeat(); scheduleReconnect(wsUrl); };
  ws.onerror = (e) => console.error("[beacon] WS error:", e);
}

function send(msg) {
  const encoded = JSON.stringify(msg);
  if (readyForServerEvents && ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(encoded);
      return;
    } catch (e) {
      console.error("[beacon] WS send failed, queueing message:", e);
    }
  }
  pendingSendQueue.push(encoded);
}

function sendNow(msg) {
  const encoded = JSON.stringify(msg);
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    pendingSendQueue.push(encoded);
    return;
  }
  try {
    ws.send(encoded);
  } catch (e) {
    console.error("[beacon] WS send failed, queueing message:", e);
    pendingSendQueue.push(encoded);
  }
}

function flushPendingSendQueue() {
  if (!readyForServerEvents || !ws || ws.readyState !== WebSocket.OPEN || pendingSendQueue.length === 0) return;

  while (pendingSendQueue.length > 0 && ws && ws.readyState === WebSocket.OPEN) {
    const encoded = pendingSendQueue.shift();
    if (encoded === undefined) break;
    try {
      ws.send(encoded);
    } catch (e) {
      console.error("[beacon] WS flush failed, preserving pending queue:", e);
      pendingSendQueue.unshift(encoded);
      return;
    }
  }
}
// Debug: expose WS state for testing when running in a browser.
if (typeof window !== "undefined") {
  window.__beaconWsState = () => ws ? ws.readyState : -1;
  window.__beaconConnectionReady = () => readyForServerEvents;
  if (window.__BEACON_ENABLE_TEST_HOOKS === true) {
    window.__beaconCloseSocketForTest = () => {
      if (!ws) return -1;
      const state = ws.readyState;
      ws.close(4000, "beacon test close");
      return state;
    };
  }
}
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
    case "model_sync": handleModelSync(msg.model, msg.version, msg.ack_clock || 0); break;
    case "patch": handlePatch(msg.ops, msg.version, msg.ack_clock || 0); break;
    case "navigate": handleServerNavigate(msg.path); break;
    case "hard_navigate": handleServerHardNavigate(msg.path); break;
    case "reload": console.log("[beacon] Hot reload — refreshing..."); location.reload(); break;
    case "heartbeat_ack": break;
    case "error": console.error("[beacon] Server error:", msg.reason); break;
  }
}

function handleMount(payload) {
  if (!appRoot) return;
  // Always morph mount HTML into the DOM. The mount is authoritative —
  // it reflects the ws_init model which may differ from SSR (e.g., auth state).
  // SSR content was a quick first paint; the mount from the runtime replaces it.
  hydrated = false;
  morphInnerHTML(appRoot, payload);
  attachEvents();
  syncHooks(appRoot);
  trace("mount", { length: payload.length });
  readyForServerEvents = true;
  flushPendingSendQueue();
}

function handleModelSync(modelJson, version, ackClock) {
  if (!window.BeaconApp) return;
  const App = window.BeaconApp;
  if (!App.decode_model) return;
  if (version < currentModelVersion) {
    trace("model_sync.stale", { version, currentModelVersion });
    return;
  }

  try {
    const result = App.decode_model(modelJson);
    if (result.isOk()) {
      clientModel = result[0];

      // Cache JSON representation for future patch diffing
      try { clientModelJson = JSON.parse(modelJson); } catch (e) { console.error("[beacon] Failed to parse cached model JSON:", e.message); console.warn("[beacon] Client patching disabled until next successful model_sync — JSON cache is null"); clientModelJson = null; }

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
      currentModelVersion = version;
      latestAckClock = Math.max(latestAckClock, ackClock);
      console.log("[beacon] Model synced v" + version);
      trace("model_sync", { version, ackClock });
      readyForServerEvents = true;
      flushPendingSendQueue();
    }
  } catch (e) {
    console.error("[beacon] Model sync decode failed:", e);
  }
}

function handlePatch(opsJson, version, ackClock) {
  if (!window.BeaconApp) return;
  const App = window.BeaconApp;
  if (version < currentModelVersion) {
    trace("patch.stale", { version, currentModelVersion });
    return;
  }
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
      currentModelVersion = version;
      latestAckClock = Math.max(latestAckClock, ackClock);
      console.log("[beacon] Patch applied v" + version + " (" + ops.length + " ops)");
      trace("patch", { version, ackClock, ops: ops.length });
    } else {
      console.error("[beacon] Patch decode failed, requesting full sync");
      console.warn("[beacon] Client-server desync detected: patch decode failed, disabling client patching until next model_sync");
      clientModelJson = null;
    }
  } catch (e) {
    console.error("[beacon] Patch apply failed:", e);
    console.warn("[beacon] Client-server desync detected: patch apply exception, disabling client patching until next model_sync");
    clientModelJson = null;
  }
}

function handleServerNavigate(path) {
  if (path && path !== location.pathname + location.search) {
    history.pushState(null, "", path);
    resetClientRouteTransientState(path);
    // Trigger navigate to server for route-change processing
    send({ type: "navigate", path: path });
  }
}

function resetClientRouteTransientState(path) {
  for (const item of pendingInputEvents.values()) {
    clearTimeout(item.timer);
  }
  pendingInputEvents.clear();
  pendingLocalEvents = [];
  renderPending = false;
  trace("route.transient_reset", { path });
}

// Hard navigation — full page reload via window.location.href.
// Used when the browser needs to make a real HTTP request (e.g., to receive Set-Cookie headers).
function handleServerHardNavigate(path) {
  if (!path) {
    console.warn("[beacon] Hard navigate: received empty path from server");
    return;
  }
  // SECURITY: Only allow same-origin relative paths to prevent open redirect attacks.
  // Protocol-relative URLs (//evil.com), absolute URLs, javascript: and data: are rejected.
  if (path.startsWith("/") && !path.startsWith("//")) {
    window.location.href = path;
  } else {
    console.error("[beacon] Hard navigate rejected: path must start with / (got:", path, ")");
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

  const t = document.createElement("template"); t.innerHTML = html; morphChildren(container, t.content); syncHooks(container);
  trace("morph", { childCount: container.childNodes.length });

  // Restore focus after morph — find the same element by name/handler
  if (focusedTag === "INPUT" || focusedTag === "TEXTAREA" || focusedTag === "SELECT") {
    let restored = null;
    if (focusedName) {
      // SECURITY: Use CSS.escape to prevent selector injection from attribute values
      const safeName = CSS.escape(focusedName);
      restored = container.querySelector(`[name="${safeName}"]`) ||
                 container.querySelector(`[data-beacon-event-input="${safeName}"]`);
    }
    if (restored) {
      if (restored !== document.activeElement) {
        restored.focus();
      }
      // Preserve active typing only while an input event is still debounced.
      // Once submit/Enter has flushed input, the server-rendered value is
      // authoritative so cleared composers do not snap back to stale text.
      if (hasPendingUnackedInput() && focusedValue !== undefined && restored.value !== focusedValue) {
        restored.value = focusedValue;
      }
      // Restore cursor position
      if (typeof selStart === "number" && restored.setSelectionRange) {
        try { restored.setSelectionRange(selStart, selEnd); } catch(e) { console.warn("[beacon] setSelectionRange failed:", e.message); }
      }
    }
  }
}

function morphChildren(op, np) {
  let oc = op.firstChild, nc = np.firstChild;
  while (nc) {
    if (!oc) { op.appendChild(nc.cloneNode(true)); trace("morph.append", { key: nodeKey(nc) }); nc = nc.nextSibling; continue; }
    if (sameNode(oc, nc)) { morphNode(oc, nc); oc = oc.nextSibling; nc = nc.nextSibling; continue; }
    const m = findMatch(oc.nextSibling, nc);
    if (m) {
      const targetKey = nodeKey(nc);
      if (targetKey) {
        op.insertBefore(m, oc);
        trace("morph.move", { key: targetKey });
        morphNode(m, nc);
        nc = nc.nextSibling;
        continue;
      }
      while (oc && oc !== m) { const nx = oc.nextSibling; unmountSubtree(oc); op.removeChild(oc); trace("morph.remove", { key: nodeKey(oc) }); oc = nx; }
      if (oc) { morphNode(oc, nc); oc = oc.nextSibling; }
      nc = nc.nextSibling;
      continue;
    }
    op.insertBefore(nc.cloneNode(true), oc); trace("morph.insert", { key: nodeKey(nc) }); nc = nc.nextSibling;
  }
  while (oc) { const nx = oc.nextSibling; unmountSubtree(oc); op.removeChild(oc); trace("morph.remove", { key: nodeKey(oc) }); oc = nx; }
}

function morphNode(o, n) {
  if (o.nodeType === 3) { if (o.textContent !== n.textContent) o.textContent = n.textContent; return; }
  if (o.nodeType !== 1) return;
  morphAttributes(o, n);
  if (preservesChildren(o)) return;
  const isFormControl = o.tagName === "INPUT" || o.tagName === "TEXTAREA" || o.tagName === "SELECT";
  if (isFormControl && o === document.activeElement) {
    if (formControlValuesDiffer(o, n)) syncFormControlState(o, n);
    return;
  }
  morphChildren(o, n);
  if (isFormControl) syncFormControlState(o, n);
}

function preservesChildren(node) {
  if (!node || !node.hasAttribute) return false;
  if (node.hasAttribute("data-beacon-preserve-children")) return true;
  const ignore = node.getAttribute("data-beacon-ignore");
  return ignore === "children" || ignore === "true";
}

function nodeKey(node) {
  if (!node || node.nodeType !== 1) return null;
  return node.getAttribute("data-beacon-key") || node.id || null;
}

function describeNode(node) {
  if (!node || node.nodeType !== 1) return "";
  const id = node.id ? "#" + node.id : "";
  const key = node.getAttribute("data-beacon-key");
  const keyed = key ? `[data-beacon-key="${key}"]` : "";
  return node.tagName.toLowerCase() + id + keyed;
}

function formControlValuesDiffer(o, n) {
  if (o.tagName === "INPUT") {
    const type = (o.getAttribute("type") || "").toLowerCase();
    if (type === "checkbox" || type === "radio") return o.checked !== n.hasAttribute("checked");
    if (type === "file") return false;
    const nextValue = n.hasAttribute("value") ? n.getAttribute("value") : "";
    return o.value !== nextValue;
  }

  if (o.tagName === "TEXTAREA") {
    const nextValue = n.hasAttribute("value") ? n.getAttribute("value") : n.textContent;
    return o.value !== nextValue;
  }

  if (o.tagName === "SELECT") {
    if (o.value !== n.value) return true;
    return Array.from(o.options).some((oOption, i) => n.options[i] && oOption.selected !== n.options[i].selected);
  }

  return false;
}

function morphAttributes(o, n) {
  for (let i = o.attributes.length - 1; i >= 0; i--) if (!n.hasAttribute(o.attributes[i].name)) o.removeAttribute(o.attributes[i].name);
  for (let i = 0; i < n.attributes.length; i++) { const nm = n.attributes[i].name, v = n.attributes[i].value; if (o.getAttribute(nm) !== v) o.setAttribute(nm, v); }
}

function syncFormControlState(o, n) {
  if (o.tagName === "TEXTAREA") {
    const nextValue = n.hasAttribute("value") ? n.getAttribute("value") : n.textContent;
    if (o.value !== nextValue) o.value = nextValue;
    return;
  }

  if (o.tagName === "INPUT") {
    const type = (o.getAttribute("type") || "").toLowerCase();
    if (type === "checkbox" || type === "radio") {
      o.checked = n.hasAttribute("checked");
      return;
    }
    if (type !== "file") {
      const nextValue = n.hasAttribute("value") ? n.getAttribute("value") : "";
      if (o.value !== nextValue) o.value = nextValue;
    }
    return;
  }

  if (o.tagName === "SELECT") {
    for (let i = 0; i < o.options.length && i < n.options.length; i++) {
      o.options[i].selected = n.options[i].selected;
    }
    if (o.value !== n.value) o.value = n.value;
  }
}

function sameNode(a, b) {
  if (a.nodeType !== b.nodeType) return false;
  if (a.nodeType === 3) return true;
  if (a.nodeType !== 1) return false;
  if (a.tagName !== b.tagName) return false;
  const aKey = nodeKey(a);
  const bKey = nodeKey(b);
  if (aKey || bKey) return aKey === bKey;
  if (a.id && b.id) return a.id === b.id;
  return true;
}
function findMatch(s, t) {
  const targetKey = nodeKey(t);
  let c = s, k = 8;
  while (c && k > 0) {
    if (targetKey ? nodeKey(c) === targetKey : sameNode(c, t)) return c;
    c = c.nextSibling;
    k--;
  }
  return null;
}

function syncHooks(root) {
  if (!root || !root.querySelectorAll) return;
  root.querySelectorAll("[data-beacon-hook]").forEach((node) => {
    const hookName = node.getAttribute("data-beacon-hook");
    const hook = hookRegistry.get(hookName);
    if (!hook) return;
    const attrs = serializeHookAttrs(node);
    const existing = mountedHooks.get(node);
    if (!existing) {
      const state = hook.mount ? hook.mount(node) : undefined;
      mountedHooks.set(node, { hookName, hook, attrs, state });
      trace("hook.mount", { hook: hookName, island: node.getAttribute("data-beacon-island") || "" });
      return;
    }
    if (existing.attrs !== attrs && existing.hook.update) {
      existing.hook.update(node, existing.state);
      mountedHooks.set(node, { ...existing, attrs });
      trace("hook.update", { hook: hookName, island: node.getAttribute("data-beacon-island") || "" });
    }
  });
}

function unmountSubtree(node) {
  if (!node) return;
  if (node.querySelectorAll) node.querySelectorAll("[data-beacon-hook]").forEach(unmountHookNode);
  unmountHookNode(node);
}

function unmountHookNode(node) {
  const existing = mountedHooks.get(node);
  if (!existing) return;
  if (existing.hook.unmount) existing.hook.unmount(node, existing.state);
  mountedHooks.delete(node);
  trace("hook.unmount", { hook: existing.hookName });
}

function serializeHookAttrs(node) {
  const watchedAttrs = hookWatchSet(node);
  return Array.from(node.attributes)
    .filter((attr) => shouldIncludeHookAttr(attr.name, watchedAttrs))
    .map((attr) => attr.name + "=" + attr.value)
    .sort()
    .join("|");
}

function hookWatchSet(node) {
  const raw = node.getAttribute("data-beacon-hook-watch");
  if (!raw) return null;
  const names = raw.split(",").map((name) => name.trim()).filter(Boolean);
  return names.length > 0 ? new Set(names) : null;
}

function shouldIncludeHookAttr(name, watchedAttrs) {
  if (name === "data-beacon-preserve-children") return false;
  if (!watchedAttrs) return true;
  return name === "data-beacon-hook"
    || name === "data-beacon-hook-watch"
    || name === "data-beacon-island"
    || watchedAttrs.has(name);
}

// === Event Delegation ===

// Helper: dispatch an event through local handling and/or server.
// Builds the wire message with optional ops for patch-based sync.
function dispatchEvent(eventName, hid, data, tp, forcedClock) {
  const clock = forcedClock ?? ++eventClock;
  const eventPayload = { name: eventName, handler_id: hid, data, target_path: tp, clock };
  if (clientInitialized) {
    const r = handleEventLocally(hid, data, eventName, tp, clock);
    if (r.action === "send") {
      if (isEventRateLimited()) {
        console.warn("[beacon] Event rate limited (>" + MAX_EVENTS_PER_SECOND + "/s)");
        return;
      }
      if (r.ops) eventPayload.ops = r.ops;
      caseSendEvent(eventPayload);
    } else {
      pendingLocalEvents.push(eventPayload);
    }
  } else {
    if (isEventRateLimited()) {
      console.warn("[beacon] Event rate limited (>" + MAX_EVENTS_PER_SECOND + "/s)");
      return;
    }
    send({ type: "event", ...eventPayload });
  }
}

function caseSendEvent(eventPayload) {
  if (pendingLocalEvents.length > 0) {
    send({ type: "event_batch", events: [...pendingLocalEvents, eventPayload] });
    pendingLocalEvents = [];
  } else {
    send({ type: "event", ...eventPayload });
  }
}

function dispatchInputEvent(hid, data, tp, debounceMs) {
  const key = hid + "\n" + tp;
  const existing = pendingInputEvents.get(key);
  if (existing) clearTimeout(existing.timer);
  const clock = ++eventClock;
  const pending = {
    hid,
    data,
    tp,
    clock,
    timer: setTimeout(() => {
      pendingInputEvents.delete(key);
      dispatchEvent("input", hid, data, tp, clock);
    }, debounceMs),
  };
  pendingInputEvents.set(key, pending);
}

function flushPendingInputEvents() {
  if (pendingInputEvents.size === 0) return;
  const pending = Array.from(pendingInputEvents.values()).sort((a, b) => a.clock - b.clock);
  pendingInputEvents.clear();
  for (const item of pending) {
    clearTimeout(item.timer);
    dispatchEvent("input", item.hid, item.data, item.tp, item.clock);
  }
}

function hasPendingUnackedInput() {
  return Array.from(pendingInputEvents.values()).some((item) => item.clock > latestAckClock);
}

function getInputDebounceMs(node) {
  const raw = node.getAttribute("data-beacon-input-debounce");
  const parsed = raw ? parseInt(raw, 10) : INPUT_DEBOUNCE_MS;
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : INPUT_DEBOUNCE_MS;
}

function attachEvents() {
  if (!appRoot) return;
  appRoot.onclick = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-click")) {
        e.preventDefault();
        flushPendingInputEvents();
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
        dispatchInputEvent(hid, data, getPath(t), getInputDebounceMs(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onchange = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-change")) {
        const hid = t.getAttribute("data-beacon-event-change");
        const data = JSON.stringify({ value: t.value || "" });
        flushPendingInputEvents();
        dispatchEvent("change", hid, data, getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onfocusin = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-focus")) {
        dispatchEvent("focus", t.getAttribute("data-beacon-event-focus"), "{}", getPath(t));
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onfocusout = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-blur")) {
        dispatchEvent("blur", t.getAttribute("data-beacon-event-blur"), "{}", getPath(t));
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
        flushPendingInputEvents();
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
        const isTextEntry = t.tagName === "INPUT" || t.tagName === "TEXTAREA";
        const isEnterSubmit = e.key === "Enter" && !e.shiftKey && !e.isComposing;
        if (isTextEntry && !isEnterSubmit) return;
        if (isEnterSubmit) e.preventDefault();
        flushPendingInputEvents();
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
    if (a.hostname.toLowerCase() !== location.hostname.toLowerCase()) return;
    if (a.hasAttribute("data-beacon-external")) return;
    if (a.target === "_blank") return;

    e.preventDefault();
    const path = a.pathname + a.search;
    if (path !== location.pathname + location.search) {
      history.pushState(null, "", path);
      resetClientRouteTransientState(path);
      send({ type: "navigate", path: path });
    }
  });

  // Handle browser back/forward
  window.addEventListener("popstate", () => {
    const path = location.pathname + location.search;
    resetClientRouteTransientState(path);
    send({ type: "navigate", path });
  });
}

// === Exports for Gleam FFI ===
export function query_selector(sel) { const el = document.querySelector(sel); return el ? { type: "Ok", 0: el } : { type: "Error", 0: undefined }; }
export function log(msg) { console.log("[beacon]", msg); return undefined; }
export function log_error(msg) { console.error("[beacon]", msg); return undefined; }

// === Auto-boot ===
// When loaded as a script tag, auto-boot: find the app root, set up navigation, connect WS.
// For base builds (no codec), this is the only entry point — initClientAfterBoot is never called.
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
