import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { instancesOf, optionalWhole, refusalOf, text, whole } from "../dist/index.js";

describe("instancesOf", () => {
  const answer = {
    instances: {
      "Shop::Item#a": { name: { value: "A" } },
      "Shop::Item#b": { name: { value: "B" } },
      "Shop::ItemGroup#g": {},
      "Other::Item#a": {},
    },
  };

  it("returns one aggregate's states keyed by the id after the #", () => {
    assert.deepEqual(instancesOf(answer, "Shop::Item"), [
      ["a", { name: { value: "A" } }],
      ["b", { name: { value: "B" } }],
    ]);
  });

  it("does not match an aggregate whose name merely starts the same way", () => {
    assert.deepEqual(instancesOf(answer, "Shop::ItemGroup"), [["g", {}]]);
  });

  it("returns nothing for an answer without instances", () => {
    assert.deepEqual(instancesOf({}, "Shop::Item"), []);
  });
});

describe("text", () => {
  it("reads a wrapped or a plain string", () => {
    assert.equal(text({ value: "Yoga" }), "Yoga");
    assert.equal(text("Yoga"), "Yoga");
  });

  it("is null for an absent, empty or non-string value", () => {
    for (const raw of [undefined, null, "", { value: "" }, { value: 3 }, {}]) assert.equal(text(raw), null, JSON.stringify(raw));
  });
});

describe("whole", () => {
  it("reads a wrapped or a plain number under the key", () => {
    assert.equal(whole({ cents: 900 }, "cents"), 900);
    assert.equal(whole({ value: 12 }, "value"), 12);
    assert.equal(whole(7, "cents"), 7);
    assert.equal(whole({ cents: "450" }, "cents"), 450);
  });

  it("is 0 when the value is absent", () => {
    assert.equal(whole(undefined, "cents"), 0);
    assert.equal(whole(null, "cents"), 0);
    assert.equal(whole({ cents: null }, "cents"), 0);
  });
});

describe("optionalWhole", () => {
  it("reads a number and is null when the attribute was left unset", () => {
    assert.equal(optionalWhole({ cents: 900 }, "cents"), 900);
    assert.equal(optionalWhole({ cents: 0 }, "cents"), 0);
    for (const raw of [undefined, null, "", { cents: null }]) assert.equal(optionalWhole(raw, "cents"), null, JSON.stringify(raw));
  });
});

describe("refusalOf", () => {
  it("takes the last refusal's kind and words", () => {
    const refusal = refusalOf({ refusals: [{ kind: "A", error: "first" }, { kind: "B", error: "second" }] }, "X.Y");
    assert.equal(refusal.kind, "B");
    assert.equal(refusal.message, "second");
    assert.equal(refusal.name, "DomainRefusal");
  });
});
