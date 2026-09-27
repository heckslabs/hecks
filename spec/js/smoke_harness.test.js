"use strict";

// Runs under node's built-in test runner: `node --test spec/js/`.
// spec/smoke_harness_node_spec.rb runs it as part of the ordinary suite.
//
// The harness is checked against a fake site on a local port, so nothing here
// needs a network or a real deployment.

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const HARNESS = path.join(__dirname, "../../lib/hecks/projections/deploy/smoke/harness.js");
const harness = require(HARNESS);

const SECRET = "test-secret";
const COOKIE = "site_session";

// Verifies a token the way a host does: the HMAC over the encoded part, then expiry.
function tokenValid(token, secret) {
  const [encoded, signature] = (token || "").split(".");
  if (!encoded || !signature) return false;
  const expected = crypto.createHmac("sha256", secret).update(encoded).digest("hex");
  if (signature.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) {
    return false;
  }
  const claims = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  return claims.exp > Math.floor(Date.now() / 1000);
}

function cookieValue(req) {
  const match = new RegExp(`${COOKIE}=([^;]+)`).exec(req.headers.cookie || "");
  return match && match[1];
}

// A fake site: `/` is open, `/protected` wants a valid session cookie and
// redirects to `/login` otherwise, `/version` answers the era the test sets.
async function fakeSite(state = {}) {
  state.eras = state.eras || ["aaa111"];
  state.versionStatus = state.versionStatus || 200;
  state.acceptAnyCookie = state.acceptAnyCookie || false;
  state.versionReads = 0;
  const server = http.createServer((req, res) => {
    if (req.url === "/") return res.writeHead(200).end("home");
    if (req.url === "/hang") return undefined;
    if (req.url === "/protected") {
      if (state.acceptAnyCookie || tokenValid(cookieValue(req), SECRET)) return res.writeHead(200).end("secret");
      return res.writeHead(302, { Location: "/login" }).end();
    }
    if (req.url === "/version") {
      if (state.versionStatus !== 200) return res.writeHead(state.versionStatus).end("no route");
      if (state.needsCookie && !tokenValid(cookieValue(req), SECRET)) return res.writeHead(401).end("{}");
      const era = state.eras[Math.min(state.versionReads, state.eras.length - 1)];
      state.versionReads += 1;
      return res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ era, build: "b1", ir_hash: "x" }));
    }
    return res.writeHead(404).end("missing");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const siteUrl = `http://127.0.0.1:${server.address().port}`;
  return { siteUrl, state, close: () => new Promise((resolve) => { server.closeAllConnections(); server.close(resolve); }) };
}

function build(config, site, env = {}) {
  const lines = [];
  const built = harness.createHarness(
    { cookieName: COOKIE, siteUrl: site.siteUrl, ...config },
    { env: { SESSION_SECRET: SECRET, ...env }, out: (text) => lines.push(text) },
  );
  return { built, output: () => lines.join("") };
}

test("signedClaim is base64url JSON plus a hex HMAC that verifies, with an expiry", () => {
  const token = harness.signedClaim(SECRET, { email: "a@b.example" }, 60);
  assert.ok(tokenValid(token, SECRET));
  assert.ok(!tokenValid(token, "another-secret"));
  const claims = JSON.parse(Buffer.from(token.split(".")[0], "base64url").toString("utf8"));
  assert.equal(claims.email, "a@b.example");
  assert.ok(claims.exp > Math.floor(Date.now() / 1000));
});

test("an expired token and an altered signature both fail verification", () => {
  assert.ok(!tokenValid(harness.accountToken(SECRET, "a@b.example", -60), SECRET));
  const good = harness.accountToken(SECRET, "a@b.example");
  assert.ok(tokenValid(good, SECRET));
  assert.ok(!tokenValid(harness.alteredSignature(good), SECRET));
});

test("the cookie name is a parameter, and the secret comes from the configured env var", async () => {
  const site = await fakeSite();
  try {
    const { built } = build({ secretEnv: "OTHER_SECRET" }, site, { SESSION_SECRET: "", OTHER_SECRET: SECRET });
    const cookie = built.sessionCookie("who@example.com");
    assert.match(cookie, new RegExp(`^${COOKIE}=`));
    assert.ok(tokenValid(cookie.slice(COOKIE.length + 1), SECRET));
  } finally {
    await site.close();
  }
});

test("a link is keyed per purpose unless a separate link secret is configured", async () => {
  const site = await fakeSite();
  try {
    const plain = build({}, site).built;
    assert.ok(tokenValid(plain.signedLink("confirm", { email: "a@b.example" }), `confirm:${SECRET}`));
    assert.ok(!tokenValid(plain.signedLink("confirm", { email: "a@b.example" }), SECRET));
    const separate = build({ linkSecretEnv: "LINK_SECRET" }, site, { LINK_SECRET: "link-only" }).built;
    assert.ok(tokenValid(separate.signedLink("confirm", { email: "a@b.example" }), "link-only"));
  } finally {
    await site.close();
  }
});

test("guest addresses are sandboxed in safe mode and plain example.com in full mode", async () => {
  const site = await fakeSite();
  try {
    const safe = build({}, site).built;
    assert.match(safe.guestEmail("reg"), /^delivered\+smoke-\d+-\d+-reg@resend\.dev$/);
    assert.ok(safe.isSmokeEmail(safe.guestEmail("reg")));
    assert.ok(!safe.isSmokeEmail("someone@resend.dev"));
    assert.ok(!safe.isSmokeEmail("delivered+smoke-1-2222222222-x@example.com"));

    const full = build({}, site, { SMOKE_MODE: "full" }).built;
    assert.match(full.guestEmail("reg"), /^smoke-\d+-\d+-reg@example\.com$/);
  } finally {
    await site.close();
  }
});

test("the sandbox mailbox and extra smoke patterns are configurable", async () => {
  const site = await fakeSite();
  try {
    const { built } = build({ sandbox: { localPart: "probe", domain: "sink.example", patterns: [/^qa\+.+@example\.org$/] } }, site);
    assert.match(built.guestEmail("x"), /^probe\+smoke-.+@sink\.example$/);
    assert.ok(built.isSmokeEmail(built.guestEmail("x")));
    assert.ok(built.isSmokeEmail("qa+old@example.org"));
    assert.ok(!built.isSmokeEmail("delivered+smoke-1-2222222222-x@resend.dev"));
  } finally {
    await site.close();
  }
});

test("a bad SMOKE_MODE, a missing site url and a missing cookie name are refused", () => {
  assert.throws(() => harness.createHarness({ cookieName: "c", siteUrl: "http://x" }, { env: { SMOKE_MODE: "loud" } }), /SMOKE_MODE/);
  assert.throws(() => harness.createHarness({ cookieName: "c" }, { env: {} }), /site url/);
  assert.throws(() => harness.createHarness({ siteUrl: "http://x" }, { env: {} }), /cookieName/);
});

test("a run id's start time decides whether a leftover is stale", () => {
  const now = Date.now();
  assert.equal(harness.runStartedAt(`smoke-12-${now}`), now);
  assert.ok(!harness.isStaleRun(`smoke-12-${now - 60_000}`, now));
  assert.ok(harness.isStaleRun(`smoke-12-${now - harness.STALE_MS - 1}`, now));
  assert.ok(harness.isStaleRun("no run id here", now));
});

test("the era allow-list ignores comments and blank lines, and SMOKE_EXPECT_ERA replaces the file", () => {
  assert.deepEqual(harness.parseEraList("# current\n\naaa111\n  bbb222  \n# old\n"), ["aaa111", "bbb222"]);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "smoke-era-"));
  const file = path.join(dir, "expected-era");
  fs.writeFileSync(file, "# eras\naaa111\n");
  assert.deepEqual(harness.expectedEras({}, file), ["aaa111"]);
  assert.deepEqual(harness.expectedEras({ SMOKE_EXPECT_ERA: "x1, y2" }, file), ["x1", "y2"]);
  assert.deepEqual(harness.expectedEras({ SMOKE_EXPECT_ERA: "" }, file), []);
  assert.deepEqual(harness.expectedEras({}, path.join(dir, "missing")), []);
});

test("the era check passes for an allowed era, fails for another, and skips without a route", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "smoke-era-"));
  fs.writeFileSync(path.join(dir, "expected-era"), "# live\naaa111\n");
  const site = await fakeSite();
  try {
    const config = { baseDir: dir, era: { file: "expected-era" } };
    assert.equal(await build(config, site).built.checkEra(), undefined);

    site.state.eras = ["zzz999"];
    await assert.rejects(build(config, site).built.checkEra(), /era zzz999 .* expected one of aaa111/);

    site.state.eras = ["aaa111"];
    site.state.versionStatus = 404;
    assert.match((await build(config, site).built.checkEra()).skipped, /no \/version route/);
  } finally {
    await site.close();
  }
});

test("the era check fails when two reads disagree, and reports no era as a failure", async () => {
  const site = await fakeSite({ eras: ["aaa111", "bbb222"] });
  try {
    await assert.rejects(build({ era: {} }, site).built.checkEra(), /changed between two reads: aaa111 then bbb222/);
    site.state.eras = [""];
    site.state.versionReads = 0;
    await assert.rejects(build({ era: {} }, site).built.checkEra(), /no era in/);
  } finally {
    await site.close();
  }
});

test("an authenticated era check sends the session cookie, and skips without a secret", async () => {
  const site = await fakeSite({ needsCookie: true });
  try {
    const config = { era: { authenticated: true } };
    assert.equal(await build(config, site).built.checkEra(), undefined);
    const noSecret = build(config, site, { SESSION_SECRET: "" }).built;
    assert.match((await noSecret.checkEra()).skipped, /no signing secret/);
  } finally {
    await site.close();
  }
});

test("forged cookies are all refused by a host that verifies them", async () => {
  const site = await fakeSite();
  try {
    const { built, output } = build({}, site);
    await built.forgedCookieChecks({ path: "/protected", what: "open the page" });
    assert.deepEqual(built.failures, []);
    assert.equal((output().match(/ ok\n/g) || []).length, 4);
  } finally {
    await site.close();
  }
});

test("forged cookies are reported when the host accepts them", async () => {
  const site = await fakeSite({ acceptAnyCookie: true });
  try {
    const { built } = build({}, site);
    await built.forgedCookieChecks({ path: "/protected" });
    assert.equal(built.failures.length, 4);
  } finally {
    await site.close();
  }
});

test("the last two forged-cookie cases skip when there is no signing secret", async () => {
  const site = await fakeSite();
  try {
    const { built, output } = build({}, site, { SESSION_SECRET: "" });
    await built.forgedCookieChecks({ path: "/protected" });
    assert.deepEqual(built.failures, []);
    assert.equal((output().match(/skipped \(no signing secret\)/g) || []).length, 2);
  } finally {
    await site.close();
  }
});

// A table of rows with the removal controls a sweep drives.
function fakeRows(rows) {
  const removedIds = [];
  return {
    rows,
    removedIds,
    list: async () => rows.filter((row) => !removedIds.includes(row.id)),
    remove: async (row) => { removedIds.push(row.id); },
  };
}

test("sweepRows removes this run's rows first, then stale leftovers in safe mode", async () => {
  const site = await fakeSite();
  try {
    const { built } = build({}, site);
    const table = fakeRows([
      { id: "old", label: "old" },
      { id: "mine", label: "mine" },
      { id: "real", label: "real" },
    ]);
    const result = await built.sweepRows({
      list: table.list,
      remove: table.remove,
      isOwn: (row) => row.id === "mine",
      isLeftover: (row) => row.id === "old",
    });
    assert.deepEqual(table.removedIds, ["mine", "old"]);
    assert.deepEqual(result, { removed: 2 });
  } finally {
    await site.close();
  }
});

test("sweepRows leaves leftovers alone in full mode but still removes its own rows", async () => {
  const site = await fakeSite();
  try {
    const { built } = build({}, site, { SMOKE_MODE: "full" });
    const table = fakeRows([{ id: "old" }, { id: "mine" }]);
    await built.sweepRows({ list: table.list, remove: table.remove, isOwn: (row) => row.id === "mine", isLeftover: () => true });
    assert.deepEqual(table.removedIds, ["mine"]);
  } finally {
    await site.close();
  }
});

test("sweepRows fails when a removed row is still listed", async () => {
  const site = await fakeSite();
  try {
    const { built } = build({}, site);
    const stuck = fakeRows([{ id: "mine", label: "the guest" }]);
    await assert.rejects(
      built.sweepRows({ list: async () => stuck.rows, remove: stuck.remove, isOwn: () => true }),
      /removed the guest but a fresh listing still has it/,
    );
  } finally {
    await site.close();
  }
});

test("sweepRows stops at its limit, and reports a skip the removal control asks for", async () => {
  const site = await fakeSite();
  try {
    const { built } = build({}, site);
    const table = fakeRows([{ id: "a" }, { id: "b" }, { id: "c" }]);
    const limited = await built.sweepRows({ list: table.list, remove: table.remove, isOwn: () => false, isLeftover: () => true, limit: 2 });
    assert.deepEqual(limited, { removed: 2 });

    const skipping = await built.sweepRows({
      list: async () => [{ id: "z" }], remove: async () => ({ skipped: "no controls yet" }), isOwn: () => true,
    });
    assert.deepEqual(skipping, { removed: 0, skipped: "no controls yet" });
  } finally {
    await site.close();
  }
});

test("run passes, runs the checks, the era check, the sweeps and both hooks in order", async () => {
  const site = await fakeSite();
  try {
    const order = [];
    const { built, output } = build({
      era: {},
      before: async () => order.push("before"),
      after: async () => order.push("after"),
      checks: [async (ctx) => ctx.check("the home page answers", async () => {
        order.push("check");
        assert.equal((await ctx.httpGet(ctx.url("/"))).status, 200);
      })],
      sweeps: [{ label: "the run's rows are gone", run: async () => { order.push("sweep"); return { removed: 0 }; } }],
    }, site);
    assert.equal(await built.run(), 0);
    assert.deepEqual(order, ["before", "check", "sweep", "after"]);
    assert.match(output(), /the home page answers\.\.\. ok/);
    assert.match(output(), /SMOKE TEST PASSED/);
  } finally {
    await site.close();
  }
});

test("a failing check does not stop the others, and the sweeps still run", async () => {
  const site = await fakeSite();
  try {
    let swept = false;
    const { built, output } = build({
      checks: [async (ctx) => {
        await ctx.check("fails", async () => { throw new Error("boom"); });
        await ctx.check("still runs", async () => {});
      }],
      sweeps: [{ label: "cleanup", run: async () => { swept = true; } }],
    }, site);
    assert.equal(await built.run(), 1);
    assert.ok(swept);
    assert.match(output(), /fails\.\.\. FAILED: boom/);
    assert.match(output(), /still runs\.\.\. ok/);
    assert.match(output(), /SMOKE TEST FAILED \(1\):\n {2}- fails/);
  } finally {
    await site.close();
  }
});

test("a check function that throws outside ctx.check is a failure, not a crash", async () => {
  const site = await fakeSite();
  try {
    const { built } = build({ checks: [async () => { throw new Error("outside"); }] }, site);
    assert.equal(await built.run(), 1);
    assert.deepEqual(built.failures, ["checks[0]"]);
  } finally {
    await site.close();
  }
});

test("a failing sweep fails the run, and a skipped check does not", async () => {
  const site = await fakeSite();
  try {
    const { built, output } = build({
      checks: [async (ctx) => ctx.check("not applicable", async () => ({ skipped: "not yet" }))],
      sweeps: [{ label: "cleanup", run: async () => { throw new Error("row stuck"); } }],
    }, site);
    assert.equal(await built.run(), 1);
    assert.match(output(), /not applicable\.\.\. skipped \(not yet\)/);
    assert.deepEqual(built.failures, ["cleanup"]);
  } finally {
    await site.close();
  }
});

test("an unreachable site is one failure and nothing else runs", async () => {
  const site = await fakeSite();
  const siteUrl = site.siteUrl;
  await site.close();
  let ran = false;
  const { built, output } = build({ siteUrl, checks: [async () => { ran = true; }] }, { siteUrl });
  assert.equal(await built.run(), 1);
  assert.ok(!ran);
  assert.doesNotMatch(output(), /SMOKE TEST PASSED/);
});

test("a request that never answers times out", async () => {
  const site = await fakeSite();
  try {
    await assert.rejects(harness.httpGet(`${site.siteUrl}/hang`, {}, { timeoutMs: 100 }), /timeout on GET/);
  } finally {
    await site.close();
  }
});

test("the command line runs a config module and exits with the run's code", async () => {
  const site = await fakeSite();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "smoke-cli-"));
  const write = (name, body) => fs.writeFileSync(path.join(dir, name), body);
  write("expected-era", "# live\naaa111\n");
  write("config.js", `module.exports = {
    cookieName: "${COOKIE}",
    era: { file: "expected-era" },
    checks: [async (ctx) => ctx.check("the home page answers", async () => {
      if ((await ctx.httpGet(ctx.url("/"))).status !== 200) throw new Error("not 200");
    })],
  };`);
  try {
    const run = (env) =>
      new Promise((resolve) => {
        const child = require("child_process").spawn(process.execPath, [HARNESS, path.join(dir, "config.js")], {
          env: { ...process.env, SMOKE_SITE_URL: site.siteUrl, SESSION_SECRET: SECRET, ...env },
        });
        let stdout = "";
        child.stdout.on("data", (chunk) => { stdout += chunk; });
        child.on("close", (code) => resolve({ code, stdout }));
      });

    const passing = await run({});
    assert.equal(passing.code, 0, passing.stdout);
    assert.match(passing.stdout, /SMOKE TEST PASSED/);

    const wrongEra = await run({ SMOKE_EXPECT_ERA: "other1" });
    assert.equal(wrongEra.code, 1);
    assert.match(wrongEra.stdout, /expected one of other1/);
  } finally {
    await site.close();
  }
});

test("the command line refuses to run without a config module", () => {
  const result = spawnSync(process.execPath, [HARNESS], { env: { ...process.env, SMOKE_CONFIG: "" }, encoding: "utf8" });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: node harness.js/);
});
