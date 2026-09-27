import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { createResilientFetch, ResilientFetchError } from "../dist/index.js";

const URL_A = "http://upstream.test/api/globals/about";
const request = { what: "global about", source: "http://upstream.test" };

const ok = (body) => Response.json(body);
const status = (code) => new Response("", { status: code, statusText: `S${code}` });
const down = () => new TypeError("fetch failed");

// A fetch that answers with `steps` in order (the last one repeats), a sleep
// that records its delays instead of waiting, and a warn that records what it
// was told.
function harness(steps = [], extra = {}) {
  const calls = [];
  const inits = [];
  const sleeps = [];
  const warnings = [];
  let script = steps;
  let i = 0;
  const fetch = async (input, init) => {
    calls.push(String(input));
    inits.push(init);
    const step = script[Math.min(i++, script.length - 1)];
    if (step instanceof Error) throw step;
    return step.clone();
  };
  const reader = createResilientFetch({
    fetch,
    sleep: async (ms) => void sleeps.push(ms),
    warn: (message) => warnings.push(message),
    retryDelaysMs: [0, 0],
    ...extra,
  });
  const next = (more) => {
    script = more;
    i = 0;
    calls.length = 0;
    inits.length = 0;
  };
  return { reader, calls, inits, sleeps, warnings, next };
}

describe("createResilientFetch", () => {
  it("returns the parsed body on success", async () => {
    const h = harness([ok({ a: 1 })]);
    assert.deepEqual(await h.reader.json(URL_A, request), { a: 1 });
    assert.equal(h.calls.length, 1);
  });

  it("retries a network error and succeeds", async () => {
    const h = harness([down(), down(), ok({ a: 2 })]);
    assert.deepEqual(await h.reader.json(URL_A, request), { a: 2 });
    assert.equal(h.calls.length, 3);
  });

  it("retries 503 and succeeds", async () => {
    const h = harness([status(503), ok({ a: 3 })]);
    assert.deepEqual(await h.reader.json(URL_A, request), { a: 3 });
  });

  it("waits the configured delays between attempts, and a call's own delays win", async () => {
    const h = harness([down()], { retryDelaysMs: [150, 500] });
    await assert.rejects(h.reader.json(URL_A, request), ResilientFetchError);
    assert.deepEqual(h.sleeps, [150, 500]);
    h.sleeps.length = 0;
    await assert.rejects(h.reader.json(URL_A, { ...request, retryDelaysMs: [7] }), ResilientFetchError);
    assert.deepEqual(h.sleeps, [7]);
  });

  it("serves the last good response when the upstream stays down, and says so", async () => {
    const h = harness([ok({ a: 4 })]);
    await h.reader.json(URL_A, request);
    h.next([down()]);
    assert.deepEqual(await h.reader.json(URL_A, request), { a: 4 });
    assert.equal(h.calls.length, 3);
    assert.deepEqual(h.warnings, ["global about: http://upstream.test unavailable (fetch failed); serving last known good"]);
  });

  it("serves the last good response on a persistent 500, without retrying it", async () => {
    const h = harness([ok({ a: 5 })]);
    await h.reader.json(URL_A, request);
    h.next([status(500)]);
    assert.deepEqual(await h.reader.json(URL_A, request), { a: 5 });
    assert.equal(h.calls.length, 1);
  });

  it("throws when down and nothing is remembered, naming what failed and why", async () => {
    const h = harness([down()]);
    await assert.rejects(h.reader.json(URL_A, request), (err) => {
      assert.ok(err instanceof ResilientFetchError);
      assert.equal(err.message, "Failed to fetch global about from http://upstream.test: fetch failed");
      assert.equal(err.failure, "fetch failed");
      return true;
    });
  });

  it("throws instead of serving stale when allowStale is false", async () => {
    const h = harness([ok({ a: 6 })]);
    await h.reader.json(URL_A, request);
    h.next([down()]);
    await assert.rejects(h.reader.json(URL_A, { ...request, allowStale: false }), /fetch failed/);
  });

  it("never retries or serves stale for a 4xx", async () => {
    const h = harness([ok({ a: 7 })]);
    await h.reader.json(URL_A, request);
    h.next([status(403)]);
    await assert.rejects(h.reader.json(URL_A, request), /403 S403/);
    assert.equal(h.calls.length, 1);
  });

  it("resolves a 404 to null only when asked", async () => {
    const h = harness([status(404)]);
    assert.equal(await h.reader.json(URL_A, { ...request, nullOn404: true }), null);
    await assert.rejects(h.reader.json(URL_A, request), /404 S404/);
  });

  it("remembers per URL", async () => {
    const h = harness([ok({ a: 8 })]);
    await h.reader.json(URL_A, request);
    h.next([down()]);
    await assert.rejects(h.reader.json("http://upstream.test/api/globals/other", request), /fetch failed/);
  });

  it("keeps each reader's memory to itself, and clear forgets it", async () => {
    const one = harness([ok({ a: 9 })]);
    await one.reader.json(URL_A, request);
    const other = harness([down()]);
    await assert.rejects(other.reader.json(URL_A, request), /fetch failed/);
    one.next([down()]);
    one.reader.clear();
    await assert.rejects(one.reader.json(URL_A, request), /fetch failed/);
  });

  it("forgets the least recently answered URL beyond maxRemembered", async () => {
    const h = harness([ok({ n: 1 })], { maxRemembered: 2 });
    for (const path of ["a", "b", "c"]) await h.reader.json(`http://upstream.test/${path}`, request);
    h.next([down()]);
    await assert.rejects(h.reader.json("http://upstream.test/a", request), /fetch failed/);
    assert.deepEqual(await h.reader.json("http://upstream.test/c", request), { n: 1 });
  });

  it("gives each attempt a timeout signal", async () => {
    const h = harness([ok({ a: 10 })]);
    await h.reader.json(URL_A, request);
    assert.ok(h.inits[0].signal instanceof AbortSignal);
  });

  // A private read carries one viewer's credentials (an editor previewing a
  // draft), so what it returns must never be shared with anyone else.
  it("sends the given headers on a private read", async () => {
    const h = harness([ok({ draft: true })]);
    await h.reader.json(URL_A, { ...request, private: true, headers: { Cookie: "session=abc" } });
    assert.deepEqual(h.inits[0].headers, { Cookie: "session=abc" });
  });

  it("never remembers a private read for later requests", async () => {
    const h = harness([ok({ draft: true })]);
    await h.reader.json(URL_A, { ...request, private: true, headers: { Cookie: "session=abc" } });
    h.next([down()]);
    await assert.rejects(h.reader.json(URL_A, request), /fetch failed/);
  });

  it("never serves a remembered public copy to a private read", async () => {
    const h = harness([ok({ published: true })]);
    await h.reader.json(URL_A, request);
    h.next([down()]);
    await assert.rejects(h.reader.json(URL_A, { ...request, private: true, headers: { Cookie: "session=abc" } }), /fetch failed/);
  });
});
