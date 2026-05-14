import assert from "node:assert/strict";
import { applyOps, diffModels } from "./beacon_client/src/beacon_client/patch.mjs";

const pollutedBefore = Object.prototype.polluted;

assert.throws(
  () => applyOps({}, [{ op: "replace", path: "/__proto__/polluted", value: true }]),
  /Unsafe patch path segment/,
);
assert.equal(Object.prototype.polluted, pollutedBefore);

assert.throws(
  () =>
    applyOps(
      { constructor: { prototype: {} } },
      [{ op: "replace", path: "/constructor/prototype/polluted", value: true }],
    ),
  /Unsafe patch path segment/,
);
assert.equal(Object.prototype.polluted, pollutedBefore);

const slashKeyPatch = diffModels({ "a/b": 1 }, { "a/b": 2 });
assert.deepEqual(slashKeyPatch, [{ op: "replace", path: "/a~1b", value: 2 }]);
assert.deepEqual(applyOps({ "a/b": 1 }, slashKeyPatch), { "a/b": 2 });

const unsafeKeyPatch = diffModels({}, JSON.parse('{"__proto__":{"polluted":true}}'));
assert.deepEqual(unsafeKeyPatch, [
  { op: "replace", path: "", value: JSON.parse('{"__proto__":{"polluted":true}}') },
]);
assert.equal(Object.prototype.polluted, pollutedBefore);
