/**
 * Beacon Client Runtime
 *
 * Minimal WebSocket client that:
 * 1. Connects to the Beacon server via WebSocket
 * 2. Sends a "join" message to receive initial state
 * 3. Receives "mount" and "patch" messages
 * 4. Applies patches to the DOM
 * 5. Captures DOM events and sends them to the server
 * 6. Sends heartbeats to keep the connection alive
 *
 * Reference: LiveView client runtime, Lustre SPA runtime.
 */

(function () {
  "use strict";

  // --- Configuration ---
  const HEARTBEAT_INTERVAL_MS = 30000; // 30 seconds, matching LiveView
  const RECONNECT_BASE_MS = 1000;
  const RECONNECT_MAX_MS = 30000;

  // --- State ---
  let ws = null;
  let heartbeatTimer = null;
  let reconnectAttempts = 0;
  let appRoot = null;
  let hydrated = false; // true if page was server-rendered
  let cachedStatics = null; // Rendered statics (sent once on mount)
  let cachedDynamics = []; // Current dynamic values
  let pendingEvents = []; // Events awaiting server acknowledgment
  let domSnapshots = {}; // DOM snapshots for rollback, keyed by clock

  // --- Initialization ---

  /**
   * Initialize the Beacon client runtime.
   * @param {Object} opts - Options
   * @param {string} opts.rootSelector - CSS selector for the app root element
   * @param {string} opts.wsUrl - WebSocket URL (defaults to ws://host/ws)
   */
  function init(opts) {
    opts = opts || {};
    const rootSelector = opts.rootSelector || "#beacon-app";
    const wsUrl =
      opts.wsUrl ||
      (location.protocol === "https:" ? "wss://" : "ws://") +
        location.host +
        "/ws";

    appRoot = document.querySelector(rootSelector);
    if (!appRoot) {
      console.error(
        "[beacon] Root element not found: " + rootSelector
      );
      return;
    }

    // Check if content was server-rendered (SSR hydration)
    hydrated = appRoot.childNodes.length > 0;
    if (hydrated) {
      console.log("[beacon] Hydrating server-rendered content");
      attachEventListeners();
    }

    console.log("[beacon] Initializing, root:", rootSelector);
    connect(wsUrl);
  }

  // --- WebSocket Connection ---

  function connect(wsUrl) {
    console.log("[beacon] Connecting to", wsUrl);

    ws = new WebSocket(wsUrl);

    ws.onopen = function () {
      console.log("[beacon] Connected");
      reconnectAttempts = 0;
      startHeartbeat();
      // Request initial state, include session token for state recovery
      var token = appRoot ? appRoot.getAttribute("data-beacon-token") || "" : "";
      send({ type: "join", token: token });
    };

    ws.onmessage = function (event) {
      handleMessage(event.data);
    };

    ws.onclose = function (event) {
      console.log("[beacon] Connection closed:", event.code, event.reason);
      stopHeartbeat();
      scheduleReconnect(wsUrl);
    };

    ws.onerror = function (error) {
      console.error("[beacon] WebSocket error:", error);
    };
  }

  function send(msg) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(msg));
    } else {
      console.warn("[beacon] Cannot send, WebSocket not open");
    }
  }

  // --- Heartbeat ---

  function startHeartbeat() {
    stopHeartbeat();
    heartbeatTimer = setInterval(function () {
      send({ type: "heartbeat" });
    }, HEARTBEAT_INTERVAL_MS);
  }

  function stopHeartbeat() {
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
  }

  // --- Reconnection with exponential backoff ---

  function scheduleReconnect(wsUrl) {
    const delay = Math.min(
      RECONNECT_BASE_MS * Math.pow(2, reconnectAttempts),
      RECONNECT_MAX_MS
    );
    reconnectAttempts++;
    console.log(
      "[beacon] Reconnecting in " + delay + "ms (attempt " + reconnectAttempts + ")"
    );
    setTimeout(function () {
      connect(wsUrl);
    }, delay);
  }

  // --- Message Handling ---

  function handleMessage(raw) {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (e) {
      console.error("[beacon] Invalid JSON from server:", raw);
      return;
    }

    switch (msg.type) {
      case "mount":
        handleMount(msg.payload);
        break;
      case "patch":
        acknowledgeClock(msg.clock || 0);
        handlePatch(msg.payload);
        break;
      case "heartbeat_ack":
        // Server acknowledged our heartbeat — connection is alive
        break;
      case "error":
        console.error("[beacon] Server error:", msg.reason);
        break;
      default:
        console.warn("[beacon] Unknown message type:", msg.type);
    }
  }

  function handleMount(payload) {
    console.log("[beacon] Mount received");
    if (!appRoot) return;

    if (hydrated) {
      // SSR hydration: DOM already has the right content.
      console.log("[beacon] Hydrating — keeping existing DOM");
      hydrated = false;
      // Still parse the Rendered data to cache statics/dynamics
      try {
        const data = JSON.parse(payload);
        if (data && data.s) {
          cachedStatics = data.s;
          cachedDynamics = extractDynamics(data);
        }
      } catch (e) { /* not JSON, ignore */ }
      attachEventListeners();
      return;
    }

    // Try to parse as Rendered JSON (has "s" key for statics)
    try {
      const data = JSON.parse(payload);
      if (data && data.s) {
        // Rendered format: store statics, extract dynamics, build HTML
        cachedStatics = data.s;
        cachedDynamics = extractDynamics(data);
        const html = zipStaticsDynamics(cachedStatics, cachedDynamics);
        morphInnerHTML(appRoot, html);
        attachEventListeners();
        return;
      }
    } catch (e) { /* not JSON */ }

    // Fallback: treat as raw HTML
    morphInnerHTML(appRoot, payload);
    attachEventListeners();
  }

  function handlePatch(payload) {
    if (!appRoot) return;
    try {
      const data = JSON.parse(payload);

      // Array → VDOM patch list (legacy format)
      if (Array.isArray(data)) {
        applyPatches(data);
        return;
      }

      // Object with "s" key → full Rendered (template structure changed)
      if (data && data.s) {
        cachedStatics = data.s;
        cachedDynamics = extractDynamics(data);
        const html = zipStaticsDynamics(cachedStatics, cachedDynamics);
        morphInnerHTML(appRoot, html);
        attachEventListeners();
        return;
      }

      // Object without "s" → Rendered diff (only changed dynamics)
      if (data && cachedStatics) {
        // Merge changed dynamics into cached
        for (const key in data) {
          if (key !== "s") {
            const idx = parseInt(key, 10);
            if (!isNaN(idx)) {
              cachedDynamics[idx] = data[key];
            }
          }
        }
        const html = zipStaticsDynamics(cachedStatics, cachedDynamics);
        morphInnerHTML(appRoot, html);
        attachEventListeners();
        return;
      }
    } catch (e) {
      // Not JSON — treat as full HTML
    }
    morphInnerHTML(appRoot, payload);
    attachEventListeners();
  }

  // --- Rendered Format Helpers ---
  // Reference: LiveView Rendered.toString() client-side reconstruction

  /**
   * Extract dynamic values from a Rendered JSON object.
   * Dynamics are stored as integer-keyed fields: {"0": "value0", "1": "value1"}
   */
  function extractDynamics(data) {
    const dynamics = [];
    let i = 0;
    while (data.hasOwnProperty(String(i))) {
      dynamics.push(data[String(i)]);
      i++;
    }
    return dynamics;
  }

  /**
   * Reconstruct HTML by zipping statics and dynamics.
   * statics: ["<div>", "</div>"], dynamics: ["hello"] → "<div>hello</div>"
   */
  function zipStaticsDynamics(statics, dynamics) {
    let html = "";
    for (let i = 0; i < statics.length; i++) {
      html += statics[i];
      if (i < dynamics.length) {
        html += dynamics[i];
      }
    }
    return html;
  }

  // --- DOM Morphing ---
  // Reference: Livewire morph algorithm, morphdom.
  // Key principle: walk old and new DOM trees in parallel,
  // updating the old tree to match the new one without replacing nodes.
  // This preserves focus, scroll position, and selections.

  /**
   * Morph the children of a container to match new HTML content.
   * Creates a temporary element from the HTML, then morphs.
   */
  function morphInnerHTML(container, html) {
    const template = document.createElement("template");
    template.innerHTML = html;
    morphChildren(container, template.content);
  }

  /**
   * Morph children of oldParent to match children of newParent.
   * Single-pass algorithm: walks both child lists in order.
   */
  function morphChildren(oldParent, newParent) {
    let oldChild = oldParent.firstChild;
    let newChild = newParent.firstChild;

    while (newChild) {
      if (!oldChild) {
        // New has more children — append remaining
        oldParent.appendChild(newChild.cloneNode(true));
        newChild = newChild.nextSibling;
        continue;
      }

      // Same node type and tag? Morph in place.
      if (isSameNode(oldChild, newChild)) {
        morphNode(oldChild, newChild);
        oldChild = oldChild.nextSibling;
        newChild = newChild.nextSibling;
        continue;
      }

      // Look ahead in old children for a matching node
      const match = findMatchingNode(oldChild.nextSibling, newChild);
      if (match) {
        // Remove old children until we reach the match
        while (oldChild && oldChild !== match) {
          const next = oldChild.nextSibling;
          oldParent.removeChild(oldChild);
          oldChild = next;
        }
        // Now oldChild === match, morph it
        if (oldChild) {
          morphNode(oldChild, newChild);
          oldChild = oldChild.nextSibling;
        }
        newChild = newChild.nextSibling;
        continue;
      }

      // No match found — insert the new node before oldChild
      oldParent.insertBefore(newChild.cloneNode(true), oldChild);
      newChild = newChild.nextSibling;
    }

    // Remove any remaining old children
    while (oldChild) {
      const next = oldChild.nextSibling;
      oldParent.removeChild(oldChild);
      oldChild = next;
    }
  }

  /**
   * Morph a single node to match a new node.
   */
  function morphNode(oldNode, newNode) {
    if (oldNode.nodeType === Node.TEXT_NODE) {
      if (oldNode.textContent !== newNode.textContent) {
        oldNode.textContent = newNode.textContent;
      }
      return;
    }

    if (oldNode.nodeType !== Node.ELEMENT_NODE) return;

    // Morph attributes
    morphAttributes(oldNode, newNode);

    // Skip morphing children of active input/textarea to preserve user edits
    const tag = oldNode.tagName;
    if ((tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") &&
        oldNode === document.activeElement) {
      return;
    }

    // Recursively morph children
    morphChildren(oldNode, newNode);
  }

  /**
   * Update attributes of oldEl to match newEl.
   */
  function morphAttributes(oldEl, newEl) {
    // Remove attributes not in new
    const oldAttrs = oldEl.attributes;
    for (let i = oldAttrs.length - 1; i >= 0; i--) {
      const name = oldAttrs[i].name;
      if (!newEl.hasAttribute(name)) {
        oldEl.removeAttribute(name);
      }
    }
    // Set attributes from new
    const newAttrs = newEl.attributes;
    for (let i = 0; i < newAttrs.length; i++) {
      const name = newAttrs[i].name;
      const value = newAttrs[i].value;
      if (oldEl.getAttribute(name) !== value) {
        oldEl.setAttribute(name, value);
      }
    }
  }

  /**
   * Check if two nodes are "the same" for morphing purposes.
   * Same if: same nodeType AND (text nodes, or elements with same tag and same id).
   */
  function isSameNode(a, b) {
    if (a.nodeType !== b.nodeType) return false;
    if (a.nodeType === Node.TEXT_NODE) return true;
    if (a.nodeType !== Node.ELEMENT_NODE) return false;
    if (a.tagName !== b.tagName) return false;
    // If both have IDs, they must match
    const aId = a.id;
    const bId = b.id;
    if (aId && bId) return aId === bId;
    return true;
  }

  /**
   * Look ahead in the old child list for a node matching newNode.
   * Returns the matching old node, or null.
   */
  function findMatchingNode(startOld, newNode) {
    let current = startOld;
    // Only look ahead a few nodes to avoid O(n^2)
    let maxLookahead = 5;
    while (current && maxLookahead > 0) {
      if (isSameNode(current, newNode)) return current;
      current = current.nextSibling;
      maxLookahead--;
    }
    return null;
  }

  // --- Patch Application ---

  /**
   * Apply a list of patches to the DOM.
   * Each patch has an "op" field describing the operation.
   */
  function applyPatches(patches) {
    for (let i = 0; i < patches.length; i++) {
      applyPatch(patches[i]);
    }
    // Re-attach event listeners after patches
    attachEventListeners();
  }

  function applyPatch(patch) {
    const node = resolveNode(patch.path);
    if (!node) {
      console.warn("[beacon] Could not resolve path:", patch.path);
      return;
    }

    switch (patch.op) {
      case "replace_text":
        if (node.nodeType === Node.TEXT_NODE) {
          node.textContent = patch.content;
        } else {
          // The node at this path might be an element with a text child
          node.textContent = patch.content;
        }
        break;

      case "replace_node": {
        const newNode = createNodeFromJson(patch.node);
        if (node.parentNode) {
          node.parentNode.replaceChild(newNode, node);
        }
        break;
      }

      case "insert_child": {
        const newChild = createNodeFromJson(patch.node);
        const ref = node.childNodes[patch.index] || null;
        node.insertBefore(newChild, ref);
        break;
      }

      case "remove_child": {
        const child = node.childNodes[patch.index];
        if (child) {
          node.removeChild(child);
        }
        break;
      }

      case "set_attr":
        if (node.setAttribute) {
          node.setAttribute(patch.name, patch.value);
        }
        break;

      case "remove_attr":
        if (node.removeAttribute) {
          node.removeAttribute(patch.name);
        }
        break;

      case "set_event":
        if (node.setAttribute) {
          node.setAttribute(
            "data-beacon-event-" + patch.event,
            patch.handler
          );
        }
        break;

      case "remove_event":
        if (node.removeAttribute) {
          node.removeAttribute("data-beacon-event-" + patch.event);
        }
        break;

      default:
        console.warn("[beacon] Unknown patch op:", patch.op);
    }
  }

  /**
   * Resolve a DOM node from a path array.
   * Path [0, 1] means: appRoot -> child[0] -> child[1]
   * Empty path [] means the appRoot itself.
   */
  function resolveNode(path) {
    let node = appRoot;
    if (!node) return null;

    // Navigate through the first child of appRoot (since appRoot is #beacon-app
    // and the actual content is inside it)
    for (let i = 0; i < path.length; i++) {
      const children = node.childNodes;
      if (path[i] >= children.length) {
        return null;
      }
      node = children[path[i]];
    }
    return node;
  }

  /**
   * Create a DOM node from a JSON node description.
   */
  function createNodeFromJson(json) {
    if (json.t === "text") {
      return document.createTextNode(json.c);
    }

    if (json.t === "el") {
      const el = document.createElement(json.tag);

      // Set attributes
      if (json.a) {
        for (let i = 0; i < json.a.length; i++) {
          const attr = json.a[i];
          if (attr.t === "attr") {
            el.setAttribute(attr.n, attr.v);
          } else if (attr.t === "event") {
            el.setAttribute("data-beacon-event-" + attr.n, attr.h);
          }
        }
      }

      // Append children
      if (json.ch) {
        for (let i = 0; i < json.ch.length; i++) {
          el.appendChild(createNodeFromJson(json.ch[i]));
        }
      }

      return el;
    }

    // Fallback: return empty text node
    console.warn("[beacon] Unknown node type:", json.t);
    return document.createTextNode("");
  }

  // --- Event Delegation ---

  /**
   * Attach event listeners using event delegation.
   * Instead of per-element listeners, we listen at the app root
   * and check for data-beacon-event-* attributes.
   *
   * Reference: LiveView and Livewire both use event delegation.
   */
  function attachEventListeners() {
    // Remove old listener to avoid duplicates
    if (appRoot._beaconClickHandler) {
      appRoot.removeEventListener("click", appRoot._beaconClickHandler);
    }
    if (appRoot._beaconInputHandler) {
      appRoot.removeEventListener("input", appRoot._beaconInputHandler);
    }
    if (appRoot._beaconSubmitHandler) {
      appRoot.removeEventListener("submit", appRoot._beaconSubmitHandler);
    }

    // Click handler
    appRoot._beaconClickHandler = function (e) {
      const target = findEventTarget(e.target, "click");
      if (target) {
        e.preventDefault();
        const handlerId = target.getAttribute("data-beacon-event-click");
        sendEvent("click", handlerId, "{}", getNodePath(target));
      }
    };
    appRoot.addEventListener("click", appRoot._beaconClickHandler);

    // Input handler
    appRoot._beaconInputHandler = function (e) {
      const target = findEventTarget(e.target, "input");
      if (target) {
        const handlerId = target.getAttribute("data-beacon-event-input");
        const value = target.value || "";
        sendEvent(
          "input",
          handlerId,
          JSON.stringify({ value: value }),
          getNodePath(target)
        );
      }
    };
    appRoot.addEventListener("input", appRoot._beaconInputHandler);

    // Submit handler
    appRoot._beaconSubmitHandler = function (e) {
      const target = findEventTarget(e.target, "submit");
      if (target) {
        e.preventDefault();
        sendEvent("submit", "{}", getNodePath(target));
      }
    };
    appRoot.addEventListener("submit", appRoot._beaconSubmitHandler);
  }

  /**
   * Walk up the DOM tree to find the nearest element with a
   * data-beacon-event-{eventName} attribute.
   */
  function findEventTarget(el, eventName) {
    const attrName = "data-beacon-event-" + eventName;
    while (el && el !== appRoot) {
      if (el.hasAttribute && el.hasAttribute(attrName)) {
        return el;
      }
      el = el.parentNode;
    }
    return null;
  }

  /**
   * Get the path of a DOM node relative to appRoot.
   * Returns a string like "0.1.0" representing the child indices.
   */
  function getNodePath(node) {
    const indices = [];
    let current = node;
    while (current && current !== appRoot) {
      const parent = current.parentNode;
      if (parent) {
        const children = parent.childNodes;
        for (let i = 0; i < children.length; i++) {
          if (children[i] === current) {
            indices.unshift(i);
            break;
          }
        }
      }
      current = current.parentNode;
    }
    return indices.join(".");
  }

  function sendEvent(name, handlerId, data, targetPath) {
    // Snapshot DOM before sending (for potential rollback)
    domSnapshots[eventClock] = appRoot.innerHTML;

    // Track as pending
    pendingEvents.push(eventClock);

    send({
      type: "event",
      name: name,
      handler_id: handlerId || "",
      data: data,
      target_path: targetPath,
      clock: eventClock,
    });

    // Clean up old snapshots (keep only last 10)
    const keys = Object.keys(domSnapshots).map(Number).sort();
    while (keys.length > 10) {
      delete domSnapshots[keys.shift()];
    }
  }

  // --- Event Clock Acknowledgment ---

  /**
   * Acknowledge a server-confirmed event clock.
   * Remove from pending queue and clean up snapshots.
   * Reference: LiveView 1.1 event clocking.
   */
  function acknowledgeClock(clock) {
    if (clock <= 0) return;
    // Remove all pending events up to this clock
    pendingEvents = pendingEvents.filter(function (c) { return c > clock; });
    // Clean up acknowledged snapshots
    const keys = Object.keys(domSnapshots).map(Number);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] <= clock) {
        delete domSnapshots[keys[i]];
      }
    }
  }

  /**
   * Check if there are pending (unacknowledged) events.
   */
  function hasPendingEvents() {
    return pendingEvents.length > 0;
  }

  // --- Public API ---
  window.Beacon = { init: init };

  // Auto-initialize if data-beacon-auto attribute is present
  if (document.currentScript && document.currentScript.hasAttribute("data-beacon-auto")) {
    document.addEventListener("DOMContentLoaded", function () {
      init();
    });
  }
})();
