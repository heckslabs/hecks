import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import { createClient, DomainRefusal, DomainUnavailable, HostClient } from "../dist/index.js";
import { fakeHost } from "./fakeHost.mjs";
import { runEventScenario } from "./scenario.mjs";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

const URL_ = "http://host.test:4322";
const clientFor = (fetch, extra = {}) => new HostClient({ domain: "Shop", url: URL_, fetch, ...extra });

// A fetch that records each request body and answers with `body`.
const answering = (body, init = { status: 200 }) => {
  const sent = [];
  const fetch = async (_url, req) => {
    sent.push(JSON.parse(String(req?.body)));
    return new Response(typeof body === "string" ? body : JSON.stringify(body), init);
  };
  return { fetch, sent };
};

const item = (cents) => ({
  instances: { "Shop::Item#y-1": { name: { value: "Yoga" }, price: { cents }, capacity: { value: 12 }, status: "open" } },
});

const reprice = (client) =>
  client.apply({
    verb: "Item.Reprice",
    to: "y-1",
    with: { price: { cents: 12000 } },
    parse: (answer) => client.instancesOf(answer, "Item"),
    confirm: (items) => items.find(([id]) => id === "y-1")?.[1].price?.cents === 12000,
  });

describe("apply", () => {
  it("sends the verb, target, arguments and role, and returns the parsed new state", async () => {
    const { fetch, sent } = answering({ ...item(12000), refusals: [] });
    const items = await reprice(clientFor(fetch, { role: "Organizer" }));
    assert.deepEqual(sent, [{ verb: "Shop::Item.Reprice", to: "y-1", with: { price: { cents: 12000 } }, role: "Organizer" }]);
    assert.equal(items[0][1].price.cents, 12000);
  });

  it("says why when the state did not change, using the last refusal", async () => {
    const { fetch } = answering({
      ...item(10800),
      refusals: [
        { kind: "GivenNotMet", error: "replayed from history" },
        { kind: "GivenNotMet", error: "Reprice refused — only an open session can be repriced" },
      ],
    });
    await assert.rejects(reprice(clientFor(fetch)), (err) => {
      assert.ok(err instanceof DomainRefusal);
      assert.equal(err.kind, "GivenNotMet");
      assert.match(err.message, /only an open session/);
      return true;
    });
  });

  it("does not trust an old refusal when the state shows the change happened", async () => {
    const { fetch } = answering({ ...item(12000), refusals: [{ kind: "GivenNotMet", error: "replayed from history" }] });
    await assert.doesNotReject(reprice(clientFor(fetch)));
  });

  it("falls back to a NotApplied refusal naming the verb when the answer reports none", async () => {
    const { fetch } = answering({ ...item(10800), refusals: [] });
    await assert.rejects(reprice(clientFor(fetch)), (err) => {
      assert.ok(err instanceof DomainRefusal);
      assert.equal(err.kind, "NotApplied");
      assert.match(err.message, /did not apply Item\.Reprice/);
      return true;
    });
  });
});

describe("reaching the domain", () => {
  it("reports an unreachable domain as unavailable", async () => {
    const fetch = async () => {
      throw new TypeError("fetch failed");
    };
    await assert.rejects(clientFor(fetch).read(), (err) => err instanceof DomainUnavailable && /could not reach the domain at http:\/\/host\.test:4322/.test(err.message));
  });

  it("reports an HTTP error, a non-JSON answer and a host error as unavailable", async () => {
    await assert.rejects(clientFor(answering("boom", { status: 502 }).fetch).read(), /HTTP 502/);
    await assert.rejects(clientFor(answering("<html>sign in</html>", { status: 200 }).fetch).read(), /did not answer with JSON/);
    await assert.rejects(
      clientFor(answering({ error: 'event missing "verb"' }).fetch).read(),
      (err) => err instanceof DomainUnavailable && /missing "verb"/.test(err.message),
    );
  });

  it("counts a request that outlives timeoutMs as unreachable", async () => {
    const hangs = (_url, req) =>
      new Promise((_resolve, reject) => req.signal.addEventListener("abort", () => reject(req.signal.reason)));
    // AbortSignal.timeout's timer does not keep the event loop alive on every Node version,
    // and this fake fetch has no socket, so hold the loop open until the timeout has fired.
    const keepAlive = setTimeout(() => {}, 2000);
    try {
      await assert.rejects(clientFor(hangs, { timeoutMs: 20 }).read(), DomainUnavailable);
    } finally {
      clearTimeout(keepAlive);
    }
  });

  it("looks the global fetch up on each call when none is injected", async () => {
    const { fetch, sent } = answering({ instances: {}, refusals: [] });
    globalThis.fetch = fetch;
    const client = new HostClient({ domain: "Shop", url: URL_ });
    await client.read();
    assert.deepEqual(sent, [{ read: true }]);
  });
});

describe("configuration", () => {
  it("posts to <url>/dispatch and trims trailing slashes from the url", async () => {
    const urls = [];
    const fetch = async (url) => {
      urls.push(url);
      return new Response("{}");
    };
    const client = new HostClient({ domain: "Shop", url: `${URL_}//`, fetch });
    assert.equal(client.url, URL_);
    await client.read();
    assert.deepEqual(urls, [`${URL_}/dispatch`]);
  });

  it("sends no role unless the client or the call names one, and a call's own role wins", async () => {
    const { fetch, sent } = answering({});
    await clientFor(fetch).dispatch("Item.Sell", {});
    await clientFor(fetch, { role: "Organizer" }).dispatch("Item.Sell", {});
    await clientFor(fetch, { role: "Organizer" }).dispatch("Item.Sell", {}, undefined, "Guest");
    assert.deepEqual(
      sent.map((body) => body.role),
      [undefined, "Organizer", "Guest"],
    );
    assert.ok(!("role" in sent[0]));
  });

  it("qualifies bare names with the domain and leaves qualified names alone", async () => {
    const { fetch, sent } = answering({});
    const client = clientFor(fetch);
    assert.equal(client.qualify("Item"), "Shop::Item");
    assert.equal(client.qualify("Other::Item"), "Other::Item");
    await client.dispatch("Other::Item.Sell", {});
    await client.dispatch("Item.Sell", {});
    assert.deepEqual(
      sent.map((body) => body.verb),
      ["Other::Item.Sell", "Shop::Item.Sell"],
    );
  });

  it("omits `to` for a command that creates and sends empty facts by default", async () => {
    const { fetch, sent } = answering({});
    await clientFor(fetch).dispatch("Item.Sell");
    assert.deepEqual(sent, [{ verb: "Shop::Item.Sell", with: {} }]);
  });

  it("requires a domain and a url, from options or the environment", () => {
    const saved = { d: process.env.HECKS_DOMAIN, u: process.env.HECKS_SERVICE_URL };
    try {
      delete process.env.HECKS_DOMAIN;
      delete process.env.HECKS_SERVICE_URL;
      assert.throws(() => new HostClient({ url: URL_ }), /needs a domain/);
      assert.throws(() => new HostClient({ domain: "Shop" }), /needs a service URL/);

      process.env.HECKS_DOMAIN = "FromEnv";
      process.env.HECKS_SERVICE_URL = "http://env.test:1/";
      const client = createClient();
      assert.equal(client.domain, "FromEnv");
      assert.equal(client.url, "http://env.test:1");

      const explicit = createClient({ domain: "Shop", url: URL_ });
      assert.equal(explicit.domain, "Shop");
      assert.equal(explicit.url, URL_);
    } finally {
      for (const [name, value] of [["HECKS_DOMAIN", saved.d], ["HECKS_SERVICE_URL", saved.u]]) {
        if (value === undefined) delete process.env[name];
        else process.env[name] = value;
      }
    }
  });
});

describe("against the in-process host", () => {
  it("walks the shared protocol scenario", async () => {
    const host = fakeHost();
    await runEventScenario(new HostClient({ domain: "CheckoutFixture", url: URL_, role: "Organizer", fetch: host.fetch }));
    assert.ok(host.requests.every((body) => body.read === true || body.role === "Organizer"));
  });
});
