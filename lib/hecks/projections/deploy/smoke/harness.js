#!/usr/bin/env node
"use strict";

// A client-independent smoke harness for a deployed Hecks stack.
//
// Emitted by `Hecks::Projections::Deploy::Smoke` when a domain's
// `deployed_to` block opts in with `smoke true`. It owns what every stack
// needs and nothing about any one site: the check runner and its summary,
// plain HTTP helpers, HMAC signed claims and session cookies, sandbox guest
// addresses, the expected-era check against `GET /version`, and the sweep
// that takes a run's own rows (and stale leftovers) back out. What a page
// or flow should answer stays in the client's own config module.
//
//   node smoke/harness.js smoke/config.js
//
// ## The config module
//
// A CommonJS module exporting an object:
//
//   siteUrl       Base URL; `SMOKE_SITE_URL` overrides it. Required.
//   cookieName    Session cookie the site reads. Required.
//   secretEnv     Env var holding the cookie-signing secret (default `SESSION_SECRET`).
//   linkSecretEnv Optional env var for a separate signing secret for emailed links;
//                 when it is set, links are signed with it as-is instead of with
//                 the per-purpose key `<purpose>:<secret>`.
//   adminEmail    Address minted into session cookies; `SMOKE_ADMIN_EMAIL` overrides.
//   preflightPath Path that must answer 200 before anything runs (default `/`).
//   era           `{ path, file, authenticated }` turns on the era check. `path` is
//                 where the site relays the domain's `GET /version` (default
//                 `/version`); `file` is the allow-list (see below); `authenticated`
//                 sends a session cookie for `adminEmail`.
//   sandbox       `{ localPart, domain, patterns }` shapes the safe-mode guest
//                 addresses; `patterns` are extra regexps that also count as smoke rows.
//   baseDir       Directory `era.file` resolves against (the CLI sets it to the
//                 config module's own directory).
//   before(ctx)   Optional; runs first, for example to launch a browser.
//   checks        Array of `async (ctx) => {}`; each calls `ctx.check(label, fn)`.
//   sweeps        Array of `{ label, run(ctx) }`; run after every check, even when
//                 checks failed, so a run cleans up after itself. `run` may return
//                 `{ skipped }`.
//   after(ctx)    Optional; runs last, for example to close a browser.
//
// Every check runs even when an earlier one fails, so one run surfaces
// everything that is wrong. The process exits 1 when any check or sweep failed.
//
// ## SMOKE_MODE
//
// `safe` (the default) tags every guest address with a sandbox mailbox that
// accepts mail and never reaches an inbox, so a run against production is
// recognisable and never mails a real person. `full` is for a throwaway
// database and uses plain example.com addresses.
//
// ## The era allow-list
//
// `GET /version` reports the era the domain booted on. `era.file` lists the
// eras allowed to be live, one id per line; blank lines and lines starting
// with `#` are ignored. `SMOKE_EXPECT_ERA` (comma-separated) replaces the
// file. With no eras listed the check only requires that an era is reported.
// A rollback or an unplanned roll fails here.

const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");

const REQUEST_TIMEOUT_MS = 8000;
const STALE_MS = 30 * 60 * 1000;
const SWEEP_LIMIT = 300;
const REFUSAL_STATUSES = [301, 302, 303, 307, 308, 401, 403];

// One request, resolved with the status, headers and body text; redirects are
// reported, never followed. The module is picked from the URL's scheme, because
// node's `http` throws on an `https://` URL.
function request(method, url, { headers = {}, body = null, timeoutMs = REQUEST_TIMEOUT_MS } = {}) {
  const client = url.startsWith("https://") ? https : http;
  return new Promise((resolve, reject) => {
    const req = client.request(url, { method, headers }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () =>
        resolve({
          status: res.statusCode,
          location: res.headers.location || "",
          headers: res.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        }),
      );
    });
    req.on("error", reject);
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`timeout on ${method} ${url}`)));
    req.end(body);
  });
}

const httpGet = (url, headers = {}, options = {}) => request("GET", url, { headers, ...options });
const httpRequest = (method, url, headers = {}, body = null, options = {}) =>
  request(method, url, { headers, body, ...options });

// A claim signed the way a Hecks host signs its own tokens: base64url JSON,
// then the hex HMAC-SHA256 of that string, joined with a dot.
function signedClaim(secret, claims, ttlSecs) {
  const payload = { ...claims, exp: Math.floor(Date.now() / 1000) + ttlSecs };
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = crypto.createHmac("sha256", secret).update(encoded).digest("hex");
  return `${encoded}.${signature}`;
}

const accountToken = (secret, email, ttlSecs = 3600) => signedClaim(secret, { email }, ttlSecs);

// The same token with its last signature digit changed, for proving a host
// verifies the signature and not just the token's shape.
function alteredSignature(token) {
  const [encoded, signature] = token.split(".");
  const last = signature.endsWith("0") ? "1" : "0";
  return `${encoded}.${signature.slice(0, -1)}${last}`;
}

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function parseEraList(text) {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
}

// The eras the domain may be running: `SMOKE_EXPECT_ERA` when set, otherwise the
// file's ids. An unreadable or absent file means "do not compare".
function expectedEras(env, file) {
  if (env.SMOKE_EXPECT_ERA !== undefined) {
    return env.SMOKE_EXPECT_ERA.split(",").map((era) => era.trim()).filter(Boolean);
  }
  if (!file) return [];
  try {
    return parseEraList(fs.readFileSync(file, "utf8"));
  } catch {
    return [];
  }
}

// The start time a run id carries (`smoke-<pid>-<ms>`), or null for any other form.
function runStartedAt(text) {
  const match = /smoke-\d+-(\d{10,})/.exec(text || "");
  return match ? Number(match[1]) : null;
}

// A run id with no readable start time counts as stale: it cannot belong to a
// run that is still going.
function isStaleRun(text, now = Date.now()) {
  const at = runStartedAt(text);
  return at === null || now - at > STALE_MS;
}

function readSettings(config, env) {
  if (!config || typeof config !== "object") throw new Error("the smoke config must export an object");
  const siteUrl = env.SMOKE_SITE_URL || config.siteUrl;
  if (!siteUrl) throw new Error("no site url: set siteUrl in the config or SMOKE_SITE_URL");
  if (!config.cookieName) throw new Error("the smoke config needs a cookieName");
  const mode = env.SMOKE_MODE || "safe";
  if (!["safe", "full"].includes(mode)) throw new Error(`SMOKE_MODE must be safe or full, not ${mode}`);
  return { siteUrl: siteUrl.replace(/\/+$/, ""), mode };
}

function createHarness(config, { env = process.env, out = (text) => process.stdout.write(text) } = {}) {
  const { siteUrl, mode } = readSettings(config, env);
  const secret = env[config.secretEnv || "SESSION_SECRET"] || "";
  const linkSecret = (config.linkSecretEnv && env[config.linkSecretEnv]) || secret;
  const adminEmail = env.SMOKE_ADMIN_EMAIL || config.adminEmail || "admin@example.com";
  // The default mailbox is an email service's sandbox address: it reports the mail as
  // delivered and never reaches an inbox, so it does not count against a sending domain.
  const sandbox = { localPart: "delivered", domain: "resend.dev", patterns: [], ...(config.sandbox || {}) };
  const baseDir = config.baseDir || process.cwd();
  const runId = `smoke-${process.pid}-${Date.now()}`;
  const failures = [];

  // Runs one named check. A throw fails the check; `{ skipped }` reports a check
  // that does not apply to this deployment yet.
  async function check(label, fn) {
    out(`  ${label}... `);
    try {
      const result = await fn();
      out(result && result.skipped ? `skipped (${result.skipped})\n` : "ok\n");
    } catch (err) {
      out(`FAILED: ${err.message}\n`);
      failures.push(label);
    }
  }

  const guestEmail = (tag) =>
    mode === "safe"
      ? `${sandbox.localPart}+${runId}-${tag}@${sandbox.domain}`
      : `${runId}-${tag}@example.com`;

  const smokeEmailPatterns = () => [
    new RegExp(`^${escapeRegExp(sandbox.localPart)}\\+smoke-.+@${escapeRegExp(sandbox.domain)}$`, "i"),
    ...sandbox.patterns,
  ];
  const isSmokeEmail = (email) => smokeEmailPatterns().some((pattern) => pattern.test(email || ""));

  const sessionToken = (email = adminEmail, ttlSecs = 3600) => accountToken(secret, email, ttlSecs);
  const cookieHeader = (value) => `${config.cookieName}=${value}`;
  const sessionCookie = (email = adminEmail, ttlSecs = 3600) => cookieHeader(sessionToken(email, ttlSecs));

  // A link's signing key is per purpose, so a link minted for one flow cannot be
  // replayed for another, unless a separate link secret was configured.
  const linkKey = (purpose) => (config.linkSecretEnv && env[config.linkSecretEnv] ? linkSecret : `${purpose}:${linkSecret}`);
  const signedLink = (purpose, claims, ttlSecs = 600) => signedClaim(linkKey(purpose), { purpose, ...claims }, ttlSecs);

  const url = (pathname) => `${siteUrl}${pathname}`;

  // Reads the era off the site's relay of `GET /version` and compares it with
  // the allow-list; two reads a moment apart must agree, since differing answers
  // mean two hosts.
  async function checkEra() {
    const era = config.era || {};
    const target = url(era.path || "/version");
    let headers = {};
    if (era.authenticated) {
      if (!secret) return { skipped: "no signing secret to authenticate with" };
      headers = { Cookie: sessionCookie() };
    }
    const res = await httpGet(target, headers);
    if (res.status === 404) return { skipped: "the deployment has no /version route yet" };
    if (res.status !== 200) throw new Error(`HTTP ${res.status}: ${res.body.slice(0, 200)}`);
    const version = JSON.parse(res.body);
    if (typeof version.era !== "string" || !version.era) throw new Error(`no era in ${res.body.slice(0, 200)}`);
    const allowed = expectedEras(env, era.file && path.resolve(baseDir, era.file));
    if (allowed.length && !allowed.includes(version.era)) {
      throw new Error(`the domain is on era ${version.era} (build ${version.build}); expected one of ${allowed.join(", ")}`);
    }
    const again = JSON.parse((await httpGet(target, headers)).body);
    if (again.era !== version.era) throw new Error(`the era changed between two reads: ${version.era} then ${again.era}`);
  }

  // Proves a protected page refuses cookies it must not honour: signed with the
  // wrong secret, not a token at all, expired, and correctly signed but altered.
  // The last two need the real secret and are skipped without one.
  async function forgedCookieChecks({ path: pathname, refused = (res) => REFUSAL_STATUSES.includes(res.status), what = "open the page" }) {
    const cases = [
      ["a cookie signed with the wrong secret", () => accountToken(`not-the-secret-${runId}`, adminEmail)],
      ["a cookie that is not a token at all", () => "garbage.value"],
      ["an expired session cookie", () => secret && accountToken(secret, adminEmail, -60)],
      ["a session cookie whose signature was altered", () => secret && alteredSignature(sessionToken())],
    ];
    for (const [label, mint] of cases) {
      await check(`${label} does not ${what}`, async () => {
        const value = mint();
        if (!value) return { skipped: "no signing secret" };
        const res = await httpGet(url(pathname), { Cookie: cookieHeader(value) });
        if (!refused(res)) throw new Error(`answered HTTP ${res.status} ${JSON.stringify(res.location)}`);
      });
    }
  }

  // Takes a run's own rows, and in safe mode stale leftovers from a run that died
  // before cleaning up, back out through the caller's own controls. Own rows go
  // first so a run that stops at the limit has still cleaned up after itself. A
  // leftover must be older than STALE_MS so two overlapping runs never remove
  // each other's rows mid-check. Rows carry an `id`; `list` answers only rows still present.
  async function sweepRows({ list, remove, isOwn, isLeftover = () => false, limit = SWEEP_LIMIT, describe = (row) => row.label || row.id }) {
    const wanted = (row) => isOwn(row) || (mode === "safe" && isLeftover(row));
    let rows = await list();
    let removed = 0;
    for (;;) {
      const candidates = rows.filter(wanted);
      const next = candidates.find(isOwn) || candidates[0];
      if (!next) break;
      const result = await remove(next);
      if (result && result.skipped) return { removed, skipped: result.skipped };
      removed += 1;
      rows = await list();
      if (rows.some((row) => row.id === next.id)) {
        throw new Error(`removed ${describe(next)} but a fresh listing still has it`);
      }
      if (removed >= limit) break;
    }
    const left = rows.filter(isOwn).map(describe);
    if (left.length) throw new Error(`this run's rows are still present after the sweep: ${left.join(", ")}`);
    return { removed };
  }

  const context = {
    siteUrl, mode, runId, secret, adminEmail, failures, check, url,
    httpGet, httpRequest, signedClaim, accountToken, alteredSignature,
    guestEmail, isSmokeEmail, isStaleRun,
    sessionToken, sessionCookie, cookieHeader, signedLink, linkKey,
    checkEra, forgedCookieChecks, sweepRows,
  };

  async function runStep(label, fn) {
    try {
      await fn(context);
    } catch (err) {
      out(`  ${label}... FAILED: ${err.message}\n`);
      failures.push(label);
    }
  }

  async function preflight() {
    const res = await httpGet(url(config.preflightPath || "/"));
    if (res.status !== 200) throw new Error(`site not reachable at ${siteUrl} (HTTP ${res.status})`);
  }

  // Runs everything and answers the exit code: 0 when every check and sweep
  // passed, 1 otherwise. A site that cannot be reached at all is one failure,
  // not a screenful.
  async function run() {
    out(`== ${config.title || "smoke"} against ${siteUrl} (${mode}) ==\n\n`);
    try {
      await preflight();
    } catch (err) {
      out(`${err.message}\n`);
      return 1;
    }
    try {
      if (config.before) await runStep("before", config.before);
      for (const [index, checks] of (config.checks || []).entries()) await runStep(`checks[${index}]`, checks);
      if (config.era) {
        out("\n== Domain version ==\n");
        await check("the domain reports the era it is running, and it is an expected one", checkEra);
      }
    } finally {
      if ((config.sweeps || []).length) out("\n== Cleanup ==\n");
      for (const sweep of config.sweeps || []) {
        await check(sweep.label, () => sweep.run(context));
      }
      if (config.after) await runStep("after", config.after);
    }
    return summarize();
  }

  function summarize() {
    if (failures.length === 0) {
      out("\nSMOKE TEST PASSED\n");
      return 0;
    }
    out(`\nSMOKE TEST FAILED (${failures.length}):\n`);
    for (const failure of failures) out(`  - ${failure}\n`);
    return 1;
  }

  return { ...context, run };
}

module.exports = {
  createHarness, request, httpGet, httpRequest, signedClaim, accountToken, alteredSignature,
  parseEraList, expectedEras, runStartedAt, isStaleRun, STALE_MS, SWEEP_LIMIT,
};

if (require.main === module) {
  const configPath = process.argv[2] || process.env.SMOKE_CONFIG;
  if (!configPath) {
    console.error("usage: node harness.js <config module> (or set SMOKE_CONFIG)");
    process.exit(2);
  }
  const resolved = path.resolve(configPath);
  const config = { baseDir: path.dirname(resolved), ...require(resolved) };
  createHarness(config)
    .run()
    .then((code) => process.exit(code))
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
