import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { pastedKeys, savedMessage } from "../dist/index.js";

const form = (fields) => {
  const data = new FormData();
  for (const [name, value] of Object.entries(fields)) data.set(name, value);
  return data;
};

describe("pastedKeys", () => {
  it("trims both pasted keys and passes them on unchanged otherwise", () => {
    const result = pastedKeys(form({ secret_key: "  rk_test_FAKEsecretKEY0001 \n", publishable_key: "\tpk_test_FAKEpublishable0001 " }));
    assert.deepEqual(result, { keys: { secret_key: "rk_test_FAKEsecretKEY0001", publishable_key: "pk_test_FAKEpublishable0001" } });
  });

  it("asks for whatever is missing in plain words, never repeating what was pasted", () => {
    assert.deepEqual(pastedKeys(form({})), { error: "Paste both keys to save them." });
    assert.deepEqual(pastedKeys(form({ secret_key: "  ", publishable_key: "   " })), { error: "Paste both keys to save them." });
    const noRestricted = pastedKeys(form({ publishable_key: "pk_test_FAKEpublishable0001" }));
    assert.deepEqual(noRestricted, { error: "Paste the restricted key as well." });
    const noPublishable = pastedKeys(form({ secret_key: "rk_test_FAKEsecretKEY0001" }));
    assert.deepEqual(noPublishable, { error: "Paste the publishable key as well." });
    for (const result of [noRestricted, noPublishable]) {
      assert.ok(!/(rk|pk)_(test|live)_/.test(result.error), "an error must not repeat a pasted key");
    }
  });

  it("reads any object with a get, such as a Map", () => {
    const fields = new Map([["secret_key", " rk_live_x "], ["publishable_key", "pk_live_y"]]);
    assert.deepEqual(pastedKeys(fields), { keys: { secret_key: "rk_live_x", publishable_key: "pk_live_y" } });
  });
});

describe("savedMessage", () => {
  it("names the business and the mode, with a plain fallback", () => {
    assert.equal(savedMessage("Example Studio", "live"), "Saved. Connected to Example Studio in live mode.");
    assert.equal(savedMessage("  Example Studio ", "test"), "Saved. Connected to Example Studio in test mode.");
    assert.equal(savedMessage(null, undefined), "Saved. Connected to your Stripe account in test mode.");
    assert.equal(savedMessage("", "live"), "Saved. Connected to your Stripe account in live mode.");
  });
});
