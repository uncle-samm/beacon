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

    // Build handler registry via phantom render (SSR already rendered DOM)
    App.start_render();
    App.view_to_html(clientModel, clientLocal);
    clientRegistry = App.finish_render();
    clientInitialized = true;
    console.log("[beacon] Client-side execution ready");
  } catch (e) {
    console.error("[beacon] initClient failed:", e);
  }
}

function clientRender() {
  if (!clientInitialized || !appRoot) return;
  const App = window.BeaconApp;
  App.start_render();
  const html = App.view_to_html(clientModel, clientLocal);
  clientRegistry = App.finish_render();
  morphInnerHTML(appRoot, html);
  attachEvents();
}

// Returns true if the event needs to be sent to the server.
function handleEventLocally(handlerId, eventData) {
  if (!clientInitialized) return true;
  const App = window.BeaconApp;

  const result = App.resolve_handler(clientRegistry, handlerId, eventData);
  if (!result.isOk()) return true;

  try {
    const msg = result[0];
    const updateResult = App.update(clientModel, clientLocal, msg);
    clientModel = updateResult[0];
    clientLocal = updateResult[1];
    clientRender();
    return App.msg_affects_model(msg);
  } catch (e) {
    console.error("[beacon] Local update failed, falling back to server-only:", e);
    clientInitialized = false; // disable local execution
    return true;
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
  const t = document.createElement("template"); t.innerHTML = html; morphChildren(container, t.content);
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
        if (clientInitialized) {
          const needsServer = handleEventLocally(hid, "{}");
          if (needsServer) {
            send({ type: "event", name: "click", handler_id: hid, data: "{}", target_path: getPath(t), clock: eventClock });
          }
        } else {
          send({ type: "event", name: "click", handler_id: hid, data: "{}", target_path: getPath(t), clock: eventClock });
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
        if (clientInitialized) {
          const needsServer = handleEventLocally(hid, data);
          if (needsServer) {
            send({ type: "event", name: "input", handler_id: hid, data: data, target_path: getPath(t), clock: eventClock });
          }
        } else {
          send({ type: "event", name: "input", handler_id: hid, data: data, target_path: getPath(t), clock: eventClock });
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
        if (clientInitialized) {
          const needsServer = handleEventLocally(hid, "{}");
          if (needsServer) {
            send({ type: "event", name: "submit", handler_id: hid, data: "{}", target_path: getPath(t), clock: eventClock });
          }
        } else {
          send({ type: "event", name: "submit", handler_id: hid, data: "{}", target_path: getPath(t), clock: eventClock });
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
