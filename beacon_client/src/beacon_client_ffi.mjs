// Beacon client-side FFI — JavaScript implementations for browser runtime.

// === Process Dictionary (handler registry storage) ===
// Uses a module-level object instead of BEAM process dictionary.
const _pd = {};

export function pd_set(key, value) {
  _pd[key] = value;
  return undefined;  // Gleam's Nil
}

export function pd_get(key) {
  if (key in _pd) {
    return { type: "Ok", 0: _pd[key] };
  }
  return { type: "Error", 0: undefined };
}

// === DOM Operations ===

export function query_selector(selector) {
  const el = document.querySelector(selector);
  if (el) return { type: "Ok", 0: el };
  return { type: "Error", 0: undefined };
}

export function set_inner_html(el, html) {
  el.innerHTML = html;
  return undefined;
}

export function get_attribute(el, name) {
  const val = el.getAttribute(name);
  if (val !== null) return { type: "Ok", 0: val };
  return { type: "Error", 0: undefined };
}

export function add_event_listener(el, event_name, callback) {
  el.addEventListener(event_name, callback);
  return undefined;
}

export function morph_html(container, html) {
  const template = document.createElement("template");
  template.innerHTML = html;
  morphChildren(container, template.content);
  return undefined;
}

// === WebSocket ===

let _ws = null;
let _on_message = null;

export function ws_connect(url, on_message) {
  _on_message = on_message;
  _ws = new WebSocket(url);
  _ws.onmessage = (e) => on_message(e.data);
  _ws.onclose = () => {
    setTimeout(() => ws_connect(url, on_message), 1000);
  };
  return undefined;
}

export function ws_send(data) {
  if (_ws && _ws.readyState === WebSocket.OPEN) {
    _ws.send(data);
  }
  return undefined;
}

// === Morph Algorithm ===
// Same algorithm as the server-side embedded JS, but as a proper module.

function morphChildren(oldParent, newParent) {
  let oldChild = oldParent.firstChild;
  let newChild = newParent.firstChild;
  while (newChild) {
    if (!oldChild) {
      oldParent.appendChild(newChild.cloneNode(true));
      newChild = newChild.nextSibling;
      continue;
    }
    if (isSameNode(oldChild, newChild)) {
      morphNode(oldChild, newChild);
      oldChild = oldChild.nextSibling;
      newChild = newChild.nextSibling;
      continue;
    }
    const match = findMatch(oldChild.nextSibling, newChild);
    if (match) {
      while (oldChild && oldChild !== match) {
        const next = oldChild.nextSibling;
        oldParent.removeChild(oldChild);
        oldChild = next;
      }
      if (oldChild) {
        morphNode(oldChild, newChild);
        oldChild = oldChild.nextSibling;
      }
      newChild = newChild.nextSibling;
      continue;
    }
    oldParent.insertBefore(newChild.cloneNode(true), oldChild);
    newChild = newChild.nextSibling;
  }
  while (oldChild) {
    const next = oldChild.nextSibling;
    oldParent.removeChild(oldChild);
    oldChild = next;
  }
}

function morphNode(old, neu) {
  if (old.nodeType === 3) {
    if (old.textContent !== neu.textContent) old.textContent = neu.textContent;
    return;
  }
  if (old.nodeType !== 1) return;
  morphAttributes(old, neu);
  const tag = old.tagName;
  if ((tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") && old === document.activeElement) return;
  morphChildren(old, neu);
}

function morphAttributes(old, neu) {
  for (let i = old.attributes.length - 1; i >= 0; i--) {
    if (!neu.hasAttribute(old.attributes[i].name)) old.removeAttribute(old.attributes[i].name);
  }
  for (let i = 0; i < neu.attributes.length; i++) {
    const name = neu.attributes[i].name, value = neu.attributes[i].value;
    if (old.getAttribute(name) !== value) old.setAttribute(name, value);
  }
}

function isSameNode(a, b) {
  if (a.nodeType !== b.nodeType) return false;
  if (a.nodeType === 3) return true;
  if (a.nodeType !== 1) return false;
  if (a.tagName !== b.tagName) return false;
  if (a.id && b.id) return a.id === b.id;
  return true;
}

function findMatch(start, target) {
  let c = start, k = 5;
  while (c && k > 0) {
    if (isSameNode(c, target)) return c;
    c = c.nextSibling;
    k--;
  }
  return null;
}

// === Utility ===

export function log(msg) {
  console.log("[beacon]", msg);
  return undefined;
}

export function json_parse(str) {
  try {
    return { type: "Ok", 0: JSON.parse(str) };
  } catch (e) {
    return { type: "Error", 0: e.message };
  }
}
