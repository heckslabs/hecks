import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { DomainUnavailable, PaymentsConnection } from "../dist/index.js";

const connection = {
  status: "connected",
  processor: "stripe",
  label: "Stripe",
  account_ref: "self",
  mode: "test",
  display_name: "Example Studio",
  adapters: [],
  direct_modes: ["test"],
  direct: true,
  can_save_keys: true,
  can_manage: true,
  can_enable: false,
};

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// A fetch that records each request and answers with `answer`.
function answering(answer) {
  const sent = [];
  const fetch = async (url, init) => {
    sent.push({ url, ...init });
    return typeof answer === "function" ? answer(url, init) : answer.clone();
  };
  return { fetch, sent };
}

const clientFor = (fetch, extra = {}) => new PaymentsConnection({ url: "http://host.test:4322/", fetch, ...extra });

describe("PaymentsConnection", () => {
  it("shows the connection, sending the person's own session as the account cookie", async () => {
    const { fetch, sent } = answering(json(connection));
    const result = await clientFor(fetch).show("tok.sig");
    assert.deepEqual(result, { ok: true, status: 200, connection });
    assert.equal(sent[0].url, "http://host.test:4322/payments/connection");
    assert.equal(sent[0].method, "GET");
    assert.equal(sent[0].headers.Cookie, "hecks_session=tok.sig");
    assert.equal(sent[0].redirect, "manual");
    assert.equal(sent[0].body, undefined);
  });

  it("sends the session under the configured cookie name", async () => {
    const { fetch, sent } = answering(json(connection));
    await clientFor(fetch, { cookieName: "site_session" }).show("tok.sig");
    assert.equal(sent[0].headers.Cookie, "site_session=tok.sig");
  });

  it("posts pasted keys to /direct", async () => {
    const { fetch, sent } = answering(json(connection));
    const keys = { secret_key: "rk_test_a", publishable_key: "pk_test_b" };
    const result = await clientFor(fetch).saveKeys("tok.sig", keys);
    assert.equal(result.ok, true);
    assert.equal(sent[0].url, "http://host.test:4322/payments/connection/direct");
    assert.equal(sent[0].method, "POST");
    assert.deepEqual(JSON.parse(sent[0].body), keys);
  });

  it("posts a mode to /direct to use the account whose keys the host already has", async () => {
    const { fetch, sent } = answering(json(connection));
    await clientFor(fetch).useOwnAccount("tok.sig", "live");
    assert.deepEqual(JSON.parse(sent[0].body), { mode: "live" });
  });

  it("posts disconnect, enable and disable to their own routes", async () => {
    const { fetch, sent } = answering(json(connection));
    const client = clientFor(fetch);
    await client.disconnect("tok.sig");
    await client.enable("tok.sig");
    await client.disable("tok.sig");
    assert.deepEqual(
      sent.map((request) => [request.method, request.url.replace("http://host.test:4322", "")]),
      [
        ["POST", "/payments/connection/disconnect"],
        ["POST", "/payments/connection/enable"],
        ["POST", "/payments/connection/disable"],
      ],
    );
  });

  it("carries the host's own words when it refuses", async () => {
    for (const [status, error] of [
      [401, "not logged in"],
      [403, "only an Owner can manage payments"],
      [422, "One key is for test mode and the other is for live mode. Use two keys from the same mode."],
    ]) {
      const { fetch } = answering(json({ error }, status));
      assert.deepEqual(await clientFor(fetch).show("tok.sig"), { ok: false, status, error });
    }
  });

  it("does not parse an older host's redirect to an HTML login page as JSON", async () => {
    const { fetch } = answering(new Response("<html>login</html>", { status: 302, headers: { "content-type": "text/html" } }));
    assert.deepEqual(await clientFor(fetch).show("tok.sig"), { ok: false, status: 302, error: undefined });
  });

  it("does not take a 200 that is not a connection for one", async () => {
    const { fetch } = answering(json({ hello: "world" }));
    assert.deepEqual(await clientFor(fetch).show("tok.sig"), { ok: false, status: 200, error: undefined });
    const { fetch: broken } = answering(new Response("not json", { status: 200, headers: { "content-type": "application/json" } }));
    assert.deepEqual(await clientFor(broken).show("tok.sig"), { ok: false, status: 200, error: undefined });
  });

  it("reports a host that cannot be reached as unavailable", async () => {
    const fetch = async () => {
      throw new TypeError("fetch failed");
    };
    await assert.rejects(clientFor(fetch).show("tok.sig"), DomainUnavailable);
  });

  it("refuses a session that is not one cookie value, and a client with no URL", async () => {
    const { fetch, sent } = answering(json(connection));
    const client = clientFor(fetch);
    for (const session of ["", "a; b=c", "a b", "a\r\nX: y"]) {
      await assert.rejects(client.show(session), TypeError);
    }
    assert.equal(sent.length, 0);
    assert.throws(() => new PaymentsConnection({}), TypeError);
  });
});
