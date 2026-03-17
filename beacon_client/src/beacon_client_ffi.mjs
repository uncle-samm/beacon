// Beacon Client Runtime — the ONLY JavaScript that runs in the browser.
// Event delegation, WebSocket, DOM morphing, Rendered format — all here.
// When BeaconApp is available (compiled user code), runs updates LOCALLY.
// Local-only events produce ZERO WebSocket traffic.

import { Ok, Error as GleamError } from "./gleam.mjs";

// === State ===
const _pd = {};
let ws = null;
let heartbeatTimer = null;
let reconnectAttempts = 0;
let appRoot = null;
let hydrated = false;
let eventClock = 0;
let cachedStatics = null;
let cachedDynamics = [];

// === Client-Side State (when BeaconApp is available) ===
let clientModel = null;
let clientLocal = null;
let clientRegistry = null;
let clientInitialized = false;
let localEventBuffer = [];  // Buffered LOCAL events — replayed atomically on server before MODEL events
let renderPending = false;  // RAF throttle: true when a render is scheduled

// === Process Dictionary (handler registry storage) ===
export function pd_set(key, value) { _pd[key] = value; return undefined; }
export function pd_get(key) {
  return key in _pd ? new Ok(_pd[key]) : new GleamError(undefined);
}

// === Client-Side Execution ===
export function initClient() {
  if (clientInitialized || !window.BeaconApp) return;
  const App = window.BeaconApp;
  if (!App.init || !App.init_local || !App.update || !App.view_to_html) return;

  try {
    clientModel = App.init();
    clientLocal = App.init_local(clientModel);

    // Build handler registry via phantom render
    App.start_render();
    const clientHtml = App.view_to_html(clientModel, clientLocal);
    clientRegistry = App.finish_render();

    // Verify client render matches server SSR before enabling local execution
    const serverText = (appRoot?.textContent || "").substring(0, 30).trim();
    const tpl = document.createElement("template");
    tpl.innerHTML = clientHtml;
    const clientText = tpl.content.textContent.substring(0, 30).trim();
    console.log("[beacon] Mismatch check: client='" + clientText + "' server='" + serverText + "'");
    if (serverText && clientText && clientText !== serverText) {
      console.log("[beacon] Server-only mode — compiled JS is for different app");
      return;
    }

    clientInitialized = true;
    console.log("[beacon] Client-side execution ready");
  } catch (e) {
    console.error("[beacon] initClient failed:", e);
  }
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
// "local" — handled client-only, don't send
// "send" — send this single event to server
// "batched" — already sent as part of a batch
function handleEventLocally(handlerId, eventData, eventName, targetPath, clock) {
  if (!clientInitialized) return "send";
  const App = window.BeaconApp;

  const result = App.resolve_handler(clientRegistry, handlerId, eventData);
  if (!result.isOk()) return "send";

  try {
    const msg = result[0];
    const updateResult = App.update(clientModel, clientLocal, msg);
    clientModel = updateResult[0];
    clientLocal = updateResult[1];
    clientRender();

    if (App.msg_affects_model(msg)) {
      // MODEL event — flush any pending render before sending to server
      clientRenderFlush();
      // Send buffered LOCAL events + this event as atomic batch.
      if (localEventBuffer.length > 0) {
        const batch = localEventBuffer.slice();
        batch.push({ name: eventName, handler_id: handlerId, data: eventData, target_path: targetPath, clock: clock });
        send({ type: "event_batch", events: batch });
        localEventBuffer = [];
        return "batched";
      }
      return "send";  // no buffer, send single event
    } else {
      // LOCAL event — buffer for potential replay, don't send.
      // Cap buffer at 2000 events to prevent memory issues on very long drags.
      // Older events are dropped — the server will still get the final MODEL state.
      if (localEventBuffer.length < 2000) {
        localEventBuffer.push({ name: eventName, handler_id: handlerId, data: eventData, target_path: targetPath, clock: clock });
      }
      return "local";
    }
  } catch (e) {
    console.error("[beacon] Local update failed, falling back to server-only:", e);
    clientInitialized = false;
    return "send";
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
    send({ type: "join", token });
  };
  ws.onmessage = (e) => handleMessage(e.data);
  ws.onclose = () => { stopHeartbeat(); scheduleReconnect(wsUrl); };
  ws.onerror = (e) => console.error("[beacon] WS error:", e);
}

function send(msg) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg)); }
function startHeartbeat() { stopHeartbeat(); heartbeatTimer = setInterval(() => send({ type: "heartbeat" }), 30000); }
function stopHeartbeat() { if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; } }
function scheduleReconnect(wsUrl) {
  const delay = Math.min(1000 * Math.pow(2, reconnectAttempts), 30000);
  reconnectAttempts++;
  setTimeout(() => connect(wsUrl), delay);
}

export function ws_send(data) { send(JSON.parse(data)); return undefined; }
export function ws_connect(url) { connect(url); return undefined; }

// === Message Handling ===
function handleMessage(raw) {
  let msg;
  try { msg = JSON.parse(raw); } catch (e) { return; }
  switch (msg.type) {
    case "mount": handleMount(msg.payload); break;
    case "patch": handlePatch(msg.payload); break;
    case "model_sync": handleModelSync(msg.model, msg.version); break;
    case "server_fn_result": handleServerFnResult(msg.call_id, msg.result, msg.ok); break;
    case "navigate": handleServerNavigate(msg.path); break;
    case "reload": console.log("[beacon] Hot reload — refreshing..."); location.reload(); break;
    case "heartbeat_ack": break;
    case "error": console.error("[beacon] Server error:", msg.reason); break;
  }
}

function handleMount(payload) {
  if (!appRoot) return;
  if (hydrated) {
    hydrated = false;
    try { const d = JSON.parse(payload); if (d && d.s) { cachedStatics = d.s; cachedDynamics = extractDynamics(d); } } catch (e) {}
    attachEvents();
    return;
  }
  try {
    const d = JSON.parse(payload);
    if (d && d.s) { cachedStatics = d.s; cachedDynamics = extractDynamics(d); morphInnerHTML(appRoot, zipSD(cachedStatics, cachedDynamics)); attachEvents(); return; }
  } catch (e) {}
  morphInnerHTML(appRoot, payload);
  attachEvents();
}

function handlePatch(payload) {
  if (!appRoot) return;
  try {
    const d = JSON.parse(payload);
    if (Array.isArray(d)) { applyPatches(d); return; }
    if (d && d.s) { cachedStatics = d.s; cachedDynamics = extractDynamics(d); morphInnerHTML(appRoot, zipSD(cachedStatics, cachedDynamics)); attachEvents(); return; }
    if (d && cachedStatics) {
      for (const k in d) { if (k !== "s") { const idx = parseInt(k, 10); if (!isNaN(idx)) cachedDynamics[idx] = d[k]; } }
      morphInnerHTML(appRoot, zipSD(cachedStatics, cachedDynamics));
      attachEvents();
      return;
    }
  } catch (e) {}
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

      // Re-enable local execution if it was disabled by a failure
      if (!clientInitialized && clientLocal !== null) {
        clientInitialized = true;
        console.log("[beacon] Local execution re-enabled after model sync");
      }

      if (clientInitialized) {
        clientRender();
      }
      console.log("[beacon] Model synced v" + version);
    }
  } catch (e) {
    console.error("[beacon] Model sync decode failed:", e);
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
function extractDynamics(data) { const r = []; let i = 0; while (data.hasOwnProperty(String(i))) { r.push(data[String(i)]); i++; } return r; }
function zipSD(s, d) { let h = ""; for (let i = 0; i < s.length; i++) { h += s[i]; if (i < d.length) h += d[i]; } return h; }

// === Patch Application ===
function applyPatches(patches) { for (const p of patches) applyPatch(p); attachEvents(); }
function applyPatch(p) {
  const node = resolveNode(p.path);
  if (!node) return;
  switch (p.op) {
    case "replace_text": node.textContent = p.content; break;
    case "replace_node": { const nn = createNode(p.node); if (node.parentNode) node.parentNode.replaceChild(nn, node); break; }
    case "insert_child": { const nc = createNode(p.node); node.insertBefore(nc, node.childNodes[p.index] || null); break; }
    case "remove_child": { const ch = node.childNodes[p.index]; if (ch) node.removeChild(ch); break; }
    case "set_attr": if (node.setAttribute) node.setAttribute(p.name, p.value); break;
    case "remove_attr": if (node.removeAttribute) node.removeAttribute(p.name); break;
    case "set_event": if (node.setAttribute) node.setAttribute("data-beacon-event-" + p.event, p.handler); break;
    case "remove_event": if (node.removeAttribute) node.removeAttribute("data-beacon-event-" + p.event); break;
  }
}

function resolveNode(path) {
  let n = appRoot;
  for (let i = 0; i < path.length; i++) { if (!n || path[i] >= n.childNodes.length) return null; n = n.childNodes[path[i]]; }
  return n;
}

function createNode(j) {
  if (j.t === "text") return document.createTextNode(j.c);
  if (j.t === "el") {
    const el = document.createElement(j.tag);
    if (j.a) for (const a of j.a) { if (a.t === "attr") el.setAttribute(a.n, a.v); else if (a.t === "event") el.setAttribute("data-beacon-event-" + a.n, a.h); }
    if (j.ch) for (const c of j.ch) el.appendChild(createNode(c));
    return el;
  }
  return document.createTextNode("");
}

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
        try { restored.setSelectionRange(selStart, selEnd); } catch(e) {}
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
function attachEvents() {
  if (!appRoot) return;
  appRoot.onclick = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-click")) {
        e.preventDefault(); eventClock++;
        const hid = t.getAttribute("data-beacon-event-click");
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, "{}", "click", tp, eventClock);
          if (r === "send") send({ type: "event", name: "click", handler_id: hid, data: "{}", target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "click", handler_id: hid, data: "{}", target_path: tp, clock: eventClock });
        }
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.oninput = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-input")) {
        eventClock++;
        const hid = t.getAttribute("data-beacon-event-input");
        const data = JSON.stringify({ value: t.value || "" });
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, data, "input", tp, eventClock);
          if (r === "send") send({ type: "event", name: "input", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "input", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        }
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onsubmit = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-submit")) {
        e.preventDefault(); eventClock++;
        const hid = t.getAttribute("data-beacon-event-submit");
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, "{}", "submit", tp, eventClock);
          if (r === "send") send({ type: "event", name: "submit", handler_id: hid, data: "{}", target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "submit", handler_id: hid, data: "{}", target_path: tp, clock: eventClock });
        }
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmousedown = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mousedown")) {
        eventClock++;
        const hid = t.getAttribute("data-beacon-event-mousedown");
        const rect = t.getBoundingClientRect();
        const x = Math.round(e.clientX - rect.left);
        const y = Math.round(e.clientY - rect.top);
        const data = JSON.stringify({ value: x + "," + y });
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, data, "mousedown", tp, eventClock);
          if (r === "send") send({ type: "event", name: "mousedown", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "mousedown", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        }
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmouseup = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mouseup")) {
        eventClock++;
        const hid = t.getAttribute("data-beacon-event-mouseup");
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, "{}", "mouseup", tp, eventClock);
          if (r === "send") send({ type: "event", name: "mouseup", handler_id: hid, data: "{}", target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "mouseup", handler_id: hid, data: "{}", target_path: tp, clock: eventClock });
        }
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmousemove = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mousemove")) {
        eventClock++;
        const hid = t.getAttribute("data-beacon-event-mousemove");
        const rect = t.getBoundingClientRect();
        const x = Math.round(e.clientX - rect.left);
        const y = Math.round(e.clientY - rect.top);
        const data = JSON.stringify({ value: x + "," + y });
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, data, "mousemove", tp, eventClock);
          if (r === "send") send({ type: "event", name: "mousemove", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "mousemove", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        }
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
        // Add visual feedback
        setTimeout(() => { t.style.opacity = "0.4"; }, 0);
        eventClock++;
        const data = JSON.stringify({ value: dragId });
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, data, "dragstart", tp, eventClock);
          if (r === "send") send({ type: "event", name: "dragstart", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "dragstart", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        }
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
        eventClock++;
        const hid = t.getAttribute("data-beacon-event-drop");
        const data = JSON.stringify({ value: dragId });
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, data, "drop", tp, eventClock);
          if (r === "send") send({ type: "event", name: "drop", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "drop", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        }
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onkeydown = (e) => {
    let t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-keydown")) {
        eventClock++;
        const hid = t.getAttribute("data-beacon-event-keydown");
        const data = JSON.stringify({ value: e.key });
        const tp = getPath(t);
        if (clientInitialized) {
          const r = handleEventLocally(hid, data, "keydown", tp, eventClock);
          if (r === "send") send({ type: "event", name: "keydown", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        } else {
          send({ type: "event", name: "keydown", handler_id: hid, data: data, target_path: tp, clock: eventClock });
        }
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

// === Server Functions ===
const pendingServerFns = {};
let serverFnCounter = 0;

export function call_server_fn(name, args, callback) {
  const callId = "sf" + (serverFnCounter++);
  pendingServerFns[callId] = callback;
  send({ type: "server_fn", name: name, args: args, call_id: callId });
  return undefined;
}

function handleServerFnResult(callId, result, ok) {
  const cb = pendingServerFns[callId];
  if (cb) {
    delete pendingServerFns[callId];
    cb(result, ok);
  }
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
