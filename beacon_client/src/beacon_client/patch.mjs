// JSON Patch Operations for Beacon State Sync
// Automatically diffs two model JSON objects and produces minimal patch operations.
// The developer never sees these ops — they're internal to the framework.
//
// Inspired by RFC 6902 but tailored for Beacon's state-over-the-wire model.
// Operations: replace, append (detected automatically for arrays).

/**
 * Diff two model objects and produce an array of patch operations.
 * The framework calls this automatically — developers never invoke it directly.
 *
 * @param {*} oldModel - The model before update (parsed JSON object)
 * @param {*} newModel - The model after update (parsed JSON object)
 * @returns {Array} - Array of patch operations
 */
export function diffModels(oldModel, newModel) {
  if (oldModel === newModel) return [];
  if (oldModel === null || oldModel === undefined) {
    return [{ op: "replace", path: "", value: newModel }];
  }
  if (typeof oldModel !== "object" || typeof newModel !== "object") {
    return [{ op: "replace", path: "", value: newModel }];
  }

  const ops = [];
  diffObject(oldModel, newModel, "", ops);
  return ops;
}

function diffObject(oldObj, newObj, basePath, ops) {
  // Check for removed keys
  const oldKeys = Object.keys(oldObj);
  for (let i = 0; i < oldKeys.length; i++) {
    const key = oldKeys[i];
    if (!(key in newObj)) {
      ops.push({ op: "remove", path: basePath + "/" + key });
    }
  }

  // Check for added/changed keys
  const newKeys = Object.keys(newObj);
  for (let i = 0; i < newKeys.length; i++) {
    const key = newKeys[i];
    const path = basePath + "/" + key;
    const oldVal = oldObj[key];
    const newVal = newObj[key];

    if (!(key in oldObj)) {
      // New key added
      ops.push({ op: "replace", path, value: newVal });
    } else if (Array.isArray(oldVal) && Array.isArray(newVal)) {
      diffArray(oldVal, newVal, path, ops);
    } else if (
      typeof oldVal === "object" &&
      oldVal !== null &&
      typeof newVal === "object" &&
      newVal !== null &&
      !Array.isArray(oldVal)
    ) {
      diffObject(oldVal, newVal, path, ops);
    } else if (!deepEqual(oldVal, newVal)) {
      ops.push({ op: "replace", path, value: newVal });
    }
  }
}

function diffArray(oldArr, newArr, path, ops) {
  // Fast path: identical arrays
  if (oldArr.length === newArr.length && deepEqual(oldArr, newArr)) return;

  // Check for append: new array starts with all elements of old array + extra at end
  if (newArr.length > oldArr.length) {
    let isAppend = true;
    for (let i = 0; i < oldArr.length; i++) {
      if (!deepEqual(oldArr[i], newArr[i])) {
        isAppend = false;
        break;
      }
    }
    if (isAppend) {
      ops.push({ op: "append", path, value: newArr.slice(oldArr.length) });
      return;
    }
  }

  // Check for truncation (prefix match but shorter)
  if (newArr.length < oldArr.length) {
    let isPrefix = true;
    for (let i = 0; i < newArr.length; i++) {
      if (!deepEqual(oldArr[i], newArr[i])) {
        isPrefix = false;
        break;
      }
    }
    if (isPrefix) {
      // Truncation: replace with shorter array
      ops.push({ op: "replace", path, value: newArr });
      return;
    }
  }

  // Not a simple append or truncation — replace the whole array
  ops.push({ op: "replace", path, value: newArr });
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (a === null || b === null || a === undefined || b === undefined)
    return a === b;
  if (typeof a !== typeof b) return false;
  if (typeof a !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;

  if (Array.isArray(a)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }

  const keysA = Object.keys(a);
  const keysB = Object.keys(b);
  if (keysA.length !== keysB.length) return false;
  for (let i = 0; i < keysA.length; i++) {
    const key = keysA[i];
    if (!deepEqual(a[key], b[key])) return false;
  }
  return true;
}

/**
 * Apply patch operations to a model object.
 * Returns a new object — the original is not modified.
 *
 * @param {*} model - The current model (parsed JSON object)
 * @param {Array} ops - Array of patch operations
 * @returns {*} - The patched model
 */
// Keys that must never be set via patch operations to prevent prototype pollution.
const UNSAFE_KEYS = new Set(["__proto__", "constructor", "prototype"]);

export function applyOps(model, ops) {
  let result = model;
  for (let i = 0; i < ops.length; i++) {
    result = applyOp(result, ops[i]);
  }
  return result;
}

function applyOp(model, op) {
  const { path, value } = op;

  if (path === "" || path === "/") {
    // Root-level operation
    if (op.op === "replace") return value;
    return model;
  }

  // Parse path into segments
  const segments = path.split("/").filter((s) => s !== "");

  // Clone the path to the target
  const result = shallowClonePath(model, segments);
  let current = result;

  // Navigate to parent of target
  for (let i = 0; i < segments.length - 1; i++) {
    current = current[segments[i]];
  }

  const lastKey = segments[segments.length - 1];

  // Guard against prototype pollution — never allow setting dangerous keys
  if (UNSAFE_KEYS.has(lastKey)) {
    return model;
  }

  switch (op.op) {
    case "replace":
      current[lastKey] = value;
      break;
    case "append":
      if (Array.isArray(current[lastKey])) {
        current[lastKey] = current[lastKey].concat(value);
      }
      break;
    case "remove":
      if (Array.isArray(current)) {
        const idx = parseInt(lastKey, 10);
        current.splice(idx, 1);
      } else {
        delete current[lastKey];
      }
      break;
  }

  return result;
}

/**
 * Shallow-clone objects along a path so we don't mutate the original.
 * Only clones the objects on the path — siblings are shared references.
 */
function shallowClonePath(obj, segments) {
  if (typeof obj !== "object" || obj === null) return obj;
  const result = Array.isArray(obj) ? [...obj] : { ...obj };
  let current = result;
  for (let i = 0; i < segments.length - 1; i++) {
    const key = segments[i];
    const child = current[key];
    if (typeof child === "object" && child !== null) {
      current[key] = Array.isArray(child) ? [...child] : { ...child };
      current = current[key];
    } else {
      break;
    }
  }
  // Clone the leaf container too
  if (segments.length > 0) {
    const leafKey = segments[segments.length - 1];
    const leaf = current[leafKey];
    if (typeof leaf === "object" && leaf !== null && Array.isArray(leaf)) {
      current[leafKey] = [...leaf];
    }
  }
  return result;
}
