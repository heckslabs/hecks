import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { describe, it } from "node:test";

import {
  DEFAULT_ACCOUNT_COOKIE,
  accountFromCookieHeader,
  accountToken,
  cookieValue,
  resolveAccountCookieName,
  verifyAccountToken,
} from "../dist/index.js";

const SECRET = "s3cret";
const NOW = 1_800_000_000_000; // ms
const clock = (ms = NOW) => () => ms;

// A token signed the way the host signs it, from a payload written as the host
// would write it, so the tests do not depend on the module's own minting.
const sign = (claims, secret = SECRET) => {
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  return `${payload}.${createHmac("sha256", secret).update(payload).digest("hex")}`;
};
const inAMinute = () => Math.floor(NOW / 1000) + 60;

// A token minted by the host's own `account_token` (rust/host/src/auth.rs)
// for a fixed payload: the payload string below, base64url without padding,
// signed with HMAC-SHA256 under "s3cret" and written as lowercase hex. The
// same vector is asserted by the Rust unit test
// `account_token_matches_the_known_answer_vector`, so both sides agree on the
// bytes. It expires at 4102444800 (2100-01-01T00:00:00Z).
const VECTOR = {
  payload: '{"email":"chris@example.com","exp":4102444800}',
  encoded: "eyJlbWFpbCI6ImNocmlzQGV4YW1wbGUuY29tIiwiZXhwIjo0MTAyNDQ0ODAwfQ",
  signature: "143ebe224b067f9744b509937358bb39a87ed30df06aaec594934b85a288cade",
};

describe("the known-answer vector", () => {
  it("is what the host's format produces", () => {
    assert.equal(Buffer.from(VECTOR.payload).toString("base64url"), VECTOR.encoded);
    assert.equal(createHmac("sha256", SECRET).update(VECTOR.encoded).digest("hex"), VECTOR.signature);
  });

  it("verifies", () => {
    assert.deepEqual(verifyAccountToken(`${VECTOR.encoded}.${VECTOR.signature}`, SECRET, { now: clock() }), {
      email: "chris@example.com",
      exp: 4102444800,
    });
  });

  it("is what accountToken mints for the same claims", () => {
    // ttl chosen so that exp is 4102444800 under the fixed clock.
    const ttl = 4102444800 - Math.floor(NOW / 1000);
    assert.equal(accountToken(SECRET, "chris@example.com", ttl, { now: clock() }), `${VECTOR.encoded}.${VECTOR.signature}`);
  });
});

describe("verifyAccountToken", () => {
  it("returns the email and expiry of a valid token", () => {
    assert.deepEqual(verifyAccountToken(sign({ email: "person@example.com", exp: inAMinute() }), SECRET, { now: clock() }), {
      email: "person@example.com",
      exp: inAMinute(),
    });
  });

  it("round-trips a token it minted", () => {
    const token = accountToken(SECRET, "person@example.com", 60, { now: clock() });
    assert.equal(verifyAccountToken(token, SECRET, { now: clock() })?.email, "person@example.com");
  });

  it("leaves the email as signed unless asked to normalize it", () => {
    const token = sign({ email: "  New.Person@Example.COM ", exp: inAMinute() });
    assert.equal(verifyAccountToken(token, SECRET, { now: clock() })?.email, "  New.Person@Example.COM ");
    assert.equal(verifyAccountToken(token, SECRET, { now: clock(), normalizeEmail: true })?.email, "new.person@example.com");
  });

  it("refuses an email that is blank after normalizing", () => {
    const token = sign({ email: "   ", exp: inAMinute() });
    assert.equal(verifyAccountToken(token, SECRET, { now: clock(), normalizeEmail: true }), null);
  });

  it("is valid through the second it expires in and refused after", () => {
    const token = sign({ email: "person@example.com", exp: 1_800_000_000 });
    assert.ok(verifyAccountToken(token, SECRET, { now: clock(1_800_000_000_999) }));
    assert.equal(verifyAccountToken(token, SECRET, { now: clock(1_800_000_001_000) }), null);
  });

  it("refuses a token signed with another secret", () => {
    assert.equal(verifyAccountToken(sign({ email: "person@example.com", exp: inAMinute() }, "someone-else"), SECRET, { now: clock() }), null);
  });

  it("refuses a tampered payload and an upper-cased signature", () => {
    const token = sign({ email: "person@example.com", exp: inAMinute() });
    const [payload, signature] = token.split(".");
    const forged = Buffer.from(JSON.stringify({ email: "admin@example.com", exp: inAMinute() })).toString("base64url");
    assert.equal(verifyAccountToken(`${forged}.${signature}`, SECRET, { now: clock() }), null);
    assert.equal(verifyAccountToken(`${payload}.${signature.toUpperCase()}`, SECRET, { now: clock() }), null);
  });

  it("refuses a token missing an email or an integer expiry", () => {
    assert.equal(verifyAccountToken(sign({ exp: inAMinute() }), SECRET, { now: clock() }), null);
    assert.equal(verifyAccountToken(sign({ email: 7, exp: inAMinute() }), SECRET, { now: clock() }), null);
    assert.equal(verifyAccountToken(sign({ email: "a@b.c" }), SECRET, { now: clock() }), null);
    assert.equal(verifyAccountToken(sign({ email: "a@b.c", exp: "9999999999" }), SECRET, { now: clock() }), null);
    assert.equal(verifyAccountToken(sign({ email: "a@b.c", exp: -1 }), SECRET, { now: clock() }), null);
    assert.equal(verifyAccountToken(sign({ email: "a@b.c", exp: 1.5 }), SECRET, { now: clock() }), null);
  });

  it("answers null, never throws, for anything that is not a token", () => {
    const signedNonJson = (() => {
      const payload = Buffer.from("not json").toString("base64url");
      return `${payload}.${createHmac("sha256", SECRET).update(payload).digest("hex")}`;
    })();
    for (const token of ["", "garbage", "garbage.notasignature", ".", "a.b.c", signedNonJson, sign(null), sign("text"), undefined, 7]) {
      assert.equal(verifyAccountToken(token, SECRET, { now: clock() }), null, String(token));
    }
  });

  it("splits at the last dot, as the host does", () => {
    const payload = "eyJ";
    const token = `${payload}.x.${createHmac("sha256", SECRET).update(`${payload}.x`).digest("hex")}`;
    // Signed correctly over "eyJ.x", but that is not valid JSON, so null rather than a throw.
    assert.equal(verifyAccountToken(token, SECRET, { now: clock() }), null);
  });

  it("refuses to verify against an empty secret", () => {
    assert.throws(() => verifyAccountToken(sign({ email: "a@b.c", exp: inAMinute() }, ""), ""), TypeError);
    assert.throws(() => accountToken("", "a@b.c", 60), TypeError);
  });
});

describe("cookies", () => {
  const token = sign({ email: "person@example.com", exp: inAMinute() });

  it("finds one cookie among several", () => {
    assert.equal(cookieValue("a=1; hecks_session=abc.def; b=2", "hecks_session"), "abc.def");
    assert.equal(cookieValue("a=1", "hecks_session"), null);
    assert.equal(cookieValue(undefined, "hecks_session"), null);
    assert.equal(cookieValue("xhecks_session=1", "hecks_session"), null);
  });

  it("verifies the account cookie in a Cookie header", () => {
    assert.equal(accountFromCookieHeader(`theme=dark; ${DEFAULT_ACCOUNT_COOKIE}=${token}`, SECRET, { now: clock() })?.email, "person@example.com");
  });

  it("reads the cookie under a configured name, and only that one", () => {
    const header = `site_session=${token}`;
    assert.equal(accountFromCookieHeader(header, SECRET, { now: clock(), cookieName: "site_session" })?.email, "person@example.com");
    assert.equal(accountFromCookieHeader(header, SECRET, { now: clock() }), null);
  });

  it("is null when the cookie is absent or does not verify", () => {
    assert.equal(accountFromCookieHeader("", SECRET), null);
    assert.equal(accountFromCookieHeader("hecks_session=garbage", SECRET), null);
  });
});

describe("resolveAccountCookieName", () => {
  it("defaults when unset or empty, and passes a valid name through", () => {
    assert.equal(resolveAccountCookieName(undefined), "hecks_session");
    assert.equal(resolveAccountCookieName(null), "hecks_session");
    assert.equal(resolveAccountCookieName(""), "hecks_session");
    assert.equal(resolveAccountCookieName("site_session-1.a"), "site_session-1.a");
  });

  it("refuses a name that could not be written into a Set-Cookie header", () => {
    for (const name of ["a b", "a;b", "a=b", "a\n"]) assert.throws(() => resolveAccountCookieName(name), TypeError);
  });
});
