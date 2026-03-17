// Beacon Client Runtime (standalone) — server-only mode.
// Event delegation, WebSocket, DOM morphing, Rendered format.
// This file is served as a fallback when beacon_client.js hasn't been built.
// For client-side local execution, run: gleam run -m beacon/build

(function() {
"use strict";

var ws = null;
var heartbeatTimer = null;
var reconnectAttempts = 0;
var appRoot = null;
var hydrated = false;
var eventClock = 0;
var cachedStatics = null;
var cachedDynamics = [];

// === Initialization ===
function boot(rootSelector) {
  appRoot = document.querySelector(rootSelector || "#beacon-app");
  if (!appRoot) { console.error("[beacon] Root not found:", rootSelector); return; }
  hydrated = appRoot.childNodes.length > 0;
  if (hydrated) attachEvents();
  var wsUrl = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws";
  connect(wsUrl);
}

// === WebSocket ===
function connect(wsUrl) {
  ws = new WebSocket(wsUrl);
  ws.onopen = function() {
    reconnectAttempts = 0;
    startHeartbeat();
    var token = appRoot ? appRoot.getAttribute("data-beacon-token") || "" : "";
    send({ type: "join", token: token });
  };
  ws.onmessage = function(e) { handleMessage(e.data); };
  ws.onclose = function() { stopHeartbeat(); scheduleReconnect(wsUrl); };
  ws.onerror = function(e) { console.error("[beacon] WS error:", e); };
}

function send(msg) { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg)); }
function startHeartbeat() { stopHeartbeat(); heartbeatTimer = setInterval(function() { send({ type: "heartbeat" }); }, 30000); }
function stopHeartbeat() { if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; } }
function scheduleReconnect(wsUrl) {
  var delay = Math.min(1000 * Math.pow(2, reconnectAttempts), 30000);
  reconnectAttempts++;
  setTimeout(function() { connect(wsUrl); }, delay);
}

// === Message Handling ===
function handleMessage(raw) {
  var msg;
  try { msg = JSON.parse(raw); } catch (e) { return; }
  switch (msg.type) {
    case "mount": handleMount(msg.payload); break;
    case "patch": handlePatch(msg.payload); break;
    case "navigate": handleServerNavigate(msg.path); break;
    case "reload": console.log("[beacon] Hot reload — refreshing..."); location.reload(); break;
    case "heartbeat_ack": break;
    case "error": console.error("[beacon] Server error:", msg.reason); break;
    case "server_fn_result": handleServerFnResult(msg.call_id, msg.result, msg.ok); break;
  }
}

function handleMount(payload) {
  if (!appRoot) return;
  if (hydrated) {
    hydrated = false;
    try { var d = JSON.parse(payload); if (d && d.s) { cachedStatics = d.s; cachedDynamics = extractDynamics(d); } } catch (e) {}
    attachEvents();
    return;
  }
  try {
    var d = JSON.parse(payload);
    if (d && d.s) { cachedStatics = d.s; cachedDynamics = extractDynamics(d); morphInnerHTML(appRoot, zipSD(cachedStatics, cachedDynamics)); attachEvents(); return; }
  } catch (e) {}
  morphInnerHTML(appRoot, payload);
  attachEvents();
}

function handlePatch(payload) {
  if (!appRoot) return;
  try {
    var d = JSON.parse(payload);
    if (Array.isArray(d)) { applyPatches(d); return; }
    if (d && d.s) { cachedStatics = d.s; cachedDynamics = extractDynamics(d); morphInnerHTML(appRoot, zipSD(cachedStatics, cachedDynamics)); attachEvents(); return; }
    if (d && cachedStatics) {
      for (var k in d) { if (k !== "s") { var idx = parseInt(k, 10); if (!isNaN(idx)) cachedDynamics[idx] = d[k]; } }
      morphInnerHTML(appRoot, zipSD(cachedStatics, cachedDynamics));
      attachEvents();
      return;
    }
  } catch (e) {}
  morphInnerHTML(appRoot, payload);
  attachEvents();
}

function handleServerNavigate(path) {
  if (path && path !== location.pathname + location.search) {
    history.pushState(null, "", path);
    send({ type: "navigate", path: path });
  }
}

// === Rendered Format ===
function extractDynamics(data) { var r = [], i = 0; while (data.hasOwnProperty(String(i))) { r.push(data[String(i)]); i++; } return r; }
function zipSD(s, d) { var h = ""; for (var i = 0; i < s.length; i++) { h += s[i]; if (i < d.length) h += d[i]; } return h; }

// === Patch Application ===
function applyPatches(patches) { for (var i = 0; i < patches.length; i++) applyPatch(patches[i]); attachEvents(); }
function applyPatch(p) {
  var node = resolveNode(p.path);
  if (!node) return;
  switch (p.op) {
    case "replace_text": node.textContent = p.content; break;
    case "replace_node": var nn = createNode(p.node); if (node.parentNode) node.parentNode.replaceChild(nn, node); break;
    case "insert_child": var nc = createNode(p.node); node.insertBefore(nc, node.childNodes[p.index] || null); break;
    case "remove_child": var ch = node.childNodes[p.index]; if (ch) node.removeChild(ch); break;
    case "set_attr": if (node.setAttribute) node.setAttribute(p.name, p.value); break;
    case "remove_attr": if (node.removeAttribute) node.removeAttribute(p.name); break;
    case "set_event": if (node.setAttribute) node.setAttribute("data-beacon-event-" + p.event, p.handler); break;
    case "remove_event": if (node.removeAttribute) node.removeAttribute("data-beacon-event-" + p.event); break;
  }
}

function resolveNode(path) {
  var n = appRoot;
  for (var i = 0; i < path.length; i++) { if (!n || path[i] >= n.childNodes.length) return null; n = n.childNodes[path[i]]; }
  return n;
}

function createNode(j) {
  if (j.t === "text") return document.createTextNode(j.c);
  if (j.t === "el") {
    var el = document.createElement(j.tag);
    if (j.a) for (var i = 0; i < j.a.length; i++) { var a = j.a[i]; if (a.t === "attr") el.setAttribute(a.n, a.v); else if (a.t === "event") el.setAttribute("data-beacon-event-" + a.n, a.h); }
    if (j.ch) for (var i = 0; i < j.ch.length; i++) el.appendChild(createNode(j.ch[i]));
    return el;
  }
  return document.createTextNode("");
}

// === DOM Morphing ===
function morphInnerHTML(container, html) {
  var focused = document.activeElement;
  var focusedTag = focused && focused.tagName;
  var focusedName = focused && (focused.getAttribute("name") || focused.getAttribute("data-beacon-event-input"));
  var selStart = focused && focused.selectionStart;
  var selEnd = focused && focused.selectionEnd;
  var focusedValue = focused && focused.value;

  var t = document.createElement("template"); t.innerHTML = html; morphChildren(container, t.content);

  if (focusedTag === "INPUT" || focusedTag === "TEXTAREA" || focusedTag === "SELECT") {
    var restored = null;
    if (focusedName) {
      restored = container.querySelector('[name="' + focusedName + '"]') ||
                 container.querySelector('[data-beacon-event-input="' + focusedName + '"]');
    }
    if (!restored && focused.type) {
      var placeholder = focused.getAttribute("placeholder");
      if (placeholder) restored = container.querySelector(focusedTag + '[placeholder="' + placeholder + '"]');
    }
    if (restored && restored !== document.activeElement) {
      restored.focus();
      if (typeof selStart === "number" && restored.setSelectionRange) {
        try { restored.setSelectionRange(selStart, selEnd); } catch(e) {}
      }
      if (focusedValue !== undefined && restored.value !== focusedValue) restored.value = focusedValue;
    }
  }
}

function morphChildren(op, np) {
  var oc = op.firstChild, nc = np.firstChild;
  while (nc) {
    if (!oc) { op.appendChild(nc.cloneNode(true)); nc = nc.nextSibling; continue; }
    if (sameNode(oc, nc)) { morphNode(oc, nc); oc = oc.nextSibling; nc = nc.nextSibling; continue; }
    var m = findMatch(oc.nextSibling, nc);
    if (m) { while (oc && oc !== m) { var nx = oc.nextSibling; op.removeChild(oc); oc = nx; } if (oc) { morphNode(oc, nc); oc = oc.nextSibling; } nc = nc.nextSibling; continue; }
    op.insertBefore(nc.cloneNode(true), oc); nc = nc.nextSibling;
  }
  while (oc) { var nx = oc.nextSibling; op.removeChild(oc); oc = nx; }
}

function morphNode(o, n) {
  if (o.nodeType === 3) { if (o.textContent !== n.textContent) o.textContent = n.textContent; return; }
  if (o.nodeType !== 1) return;
  morphAttributes(o, n);
  if ((o.tagName === "INPUT" || o.tagName === "TEXTAREA" || o.tagName === "SELECT") && o === document.activeElement) return;
  morphChildren(o, n);
}

function morphAttributes(o, n) {
  for (var i = o.attributes.length - 1; i >= 0; i--) if (!n.hasAttribute(o.attributes[i].name)) o.removeAttribute(o.attributes[i].name);
  for (var i = 0; i < n.attributes.length; i++) { var nm = n.attributes[i].name, v = n.attributes[i].value; if (o.getAttribute(nm) !== v) o.setAttribute(nm, v); }
}

function sameNode(a, b) { if (a.nodeType !== b.nodeType) return false; if (a.nodeType === 3) return true; if (a.nodeType !== 1) return false; if (a.tagName !== b.tagName) return false; if (a.id && b.id) return a.id === b.id; return true; }
function findMatch(s, t) { var c = s, k = 5; while (c && k > 0) { if (sameNode(c, t)) return c; c = c.nextSibling; k--; } return null; }

// === Event Delegation ===
function attachEvents() {
  if (!appRoot) return;
  appRoot.onclick = function(e) {
    var t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-click")) {
        e.preventDefault(); eventClock++;
        send({ type: "event", name: "click", handler_id: t.getAttribute("data-beacon-event-click"), data: "{}", target_path: getPath(t), clock: eventClock });
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.oninput = function(e) {
    var t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-input")) {
        eventClock++;
        send({ type: "event", name: "input", handler_id: t.getAttribute("data-beacon-event-input"), data: JSON.stringify({ value: t.value || "" }), target_path: getPath(t), clock: eventClock });
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onsubmit = function(e) {
    var t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-submit")) {
        e.preventDefault(); eventClock++;
        send({ type: "event", name: "submit", handler_id: t.getAttribute("data-beacon-event-submit"), data: "{}", target_path: getPath(t), clock: eventClock });
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmousedown = function(e) {
    var t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mousedown")) {
        eventClock++;
        var rect = t.getBoundingClientRect();
        var x = Math.round(e.clientX - rect.left);
        var y = Math.round(e.clientY - rect.top);
        send({ type: "event", name: "mousedown", handler_id: t.getAttribute("data-beacon-event-mousedown"), data: JSON.stringify({ value: x + "," + y }), target_path: getPath(t), clock: eventClock });
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmouseup = function(e) {
    var t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mouseup")) {
        eventClock++;
        send({ type: "event", name: "mouseup", handler_id: t.getAttribute("data-beacon-event-mouseup"), data: "{}", target_path: getPath(t), clock: eventClock });
        return;
      }
      t = t.parentNode;
    }
  };
  appRoot.onmousemove = function(e) {
    var t = e.target;
    while (t && t !== appRoot) {
      if (t.hasAttribute && t.hasAttribute("data-beacon-event-mousemove")) {
        eventClock++;
        var rect = t.getBoundingClientRect();
        var x = Math.round(e.clientX - rect.left);
        var y = Math.round(e.clientY - rect.top);
        send({ type: "event", name: "mousemove", handler_id: t.getAttribute("data-beacon-event-mousemove"), data: JSON.stringify({ value: x + "," + y }), target_path: getPath(t), clock: eventClock });
        return;
      }
      t = t.parentNode;
    }
  };
}

function getPath(node) {
  var parts = [], c = node;
  while (c && c !== appRoot) { var p = c.parentNode; if (p) { var ch = p.childNodes; for (var i = 0; i < ch.length; i++) if (ch[i] === c) { parts.unshift(i); break; } } c = c.parentNode; }
  return parts.join(".");
}

// === Server Functions ===
var pendingServerFns = {};
var serverFnCounter = 0;

window.beaconCallServerFn = function(name, args, callback) {
  var callId = "sf" + (serverFnCounter++);
  pendingServerFns[callId] = callback;
  send({ type: "server_fn", name: name, args: args, call_id: callId });
};

function handleServerFnResult(callId, result, ok) {
  var cb = pendingServerFns[callId];
  if (cb) { delete pendingServerFns[callId]; cb(result, ok); }
}

// === SPA Navigation ===
function setupNavigation() {
  document.addEventListener("click", function(e) {
    var a = e.target.closest && e.target.closest("a[href]");
    if (!a) return;
    if (a.hostname !== location.hostname) return;
    if (a.hasAttribute("data-beacon-external")) return;
    if (a.target === "_blank") return;
    e.preventDefault();
    var path = a.pathname + a.search;
    if (path !== location.pathname + location.search) {
      history.pushState(null, "", path);
      send({ type: "navigate", path: path });
    }
  });
  window.addEventListener("popstate", function() {
    send({ type: "navigate", path: location.pathname + location.search });
  });
}

// === Auto-boot ===
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", function() { boot("#beacon-app"); setupNavigation(); });
} else {
  boot("#beacon-app"); setupNavigation();
}

})();
