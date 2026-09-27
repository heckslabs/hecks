// The host's account token, verified outside the host. After a sign-in the
// host mints a short claim of who the person is, signs it, and sets it as a
// cookie; `GET /accounts/sso-token` mints a shorter-lived copy as JSON for a
// service that wants to start its own session for the same person. This is
// the receiver's half: check the signature and the expiry, and read the
// email. It is framework independent and does no I/O, so what a service then
// does with the person (find or create a user, start a session) stays its own.
//
// The wire format is rust/host/src/auth.rs's `account_token`, byte for byte:
//
//   token     = <payload> "." <signature>
//   payload   = base64url (no padding) of the UTF-8 JSON {"email": "...", "exp": <unix seconds>}
//   signature = lowercase hex of HMAC-SHA256(secret, <payload as sent>)
//
// The host splits at the last ".", compares the signature as a plain string,
// requires `exp` to be a non-negative integer, and treats the token as
// expired once the current second is past `exp`. This module makes the same
// decisions. The one deliberate difference is that the signature is compared
// in constant time.

import { createHmac, timingSafeEqual } from "node:crypto";

/** The cookie name the account token travels in when a deploy names none. */
export const DEFAULT_ACCOUNT_COOKIE = "hecks_session";

/** The clock: the current time in milliseconds since the epoch, like `Date.now`. */
export type Clock = () => number;

/** What a verified token says. */
export interface AccountClaims {
  /** The person's email, as the host signed it unless `normalizeEmail` was set. */
  email: string;
  /** When the token stops being valid, in seconds since the epoch. */
  exp: number;
}

/** Choices for `verifyAccountToken`. */
export interface VerifyOptions {
  /** The clock the expiry is judged by. Defaults to `Date.now`. */
  now?: Clock;
  /**
   * Trim and lowercase the email, and refuse a token whose email is blank
   * afterwards. For a receiver that stores addresses in that form: an address
   * the host signed in mixed case must find the row stored for it.
   */
  normalizeEmail?: boolean;
}

/** Choices for `accountFromCookieHeader`. */
export interface CookieVerifyOptions extends VerifyOptions {
  /** The cookie the token is read from. Defaults to `hecks_session`. */
  cookieName?: string;
}

const encode = (text: string): string => Buffer.from(text, "utf8").toString("base64url");

const sign = (secret: string, payload: string): string => createHmac("sha256", secret).update(payload).digest("hex");

const nowSeconds = (now: Clock): number => Math.floor(now() / 1000);

function requireSecret(secret: string): void {
  // An empty key would verify tokens anyone can sign; a receiver with no
  // secret configured is a misconfiguration, not an anonymous host.
  if (typeof secret !== "string" || secret === "") throw new TypeError("the account token secret must be a non-empty string");
}

/**
 * Mints a token in the host's format, for tests and for a stand-in host.
 * Expires `ttlSeconds` after `now` (by the injected clock).
 */
export function accountToken(secret: string, email: string, ttlSeconds: number, opts: { now?: Clock } = {}): string {
  requireSecret(secret);
  const payload = encode(JSON.stringify({ email, exp: nowSeconds(opts.now ?? Date.now) + ttlSeconds }));
  return `${payload}.${sign(secret, payload)}`;
}

/**
 * Checks a token the host minted and returns who it names, or `null` when it
 * is malformed, signed with another secret, carries no email or expiry, or
 * has expired. Never throws for a bad token.
 * @throws {TypeError} when `secret` is empty
 */
export function verifyAccountToken(token: string, secret: string, opts: VerifyOptions = {}): AccountClaims | null {
  requireSecret(secret);
  if (typeof token !== "string") return null;
  const dot = token.lastIndexOf(".");
  if (dot < 0) return null;
  const payload = token.slice(0, dot);
  const signature = token.slice(dot + 1);

  const expected = Buffer.from(sign(secret, payload));
  const given = Buffer.from(signature);
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;

  let claims: unknown;
  try {
    claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (!claims || typeof claims !== "object") return null;
  const { exp, email } = claims as { exp?: unknown; email?: unknown };
  if (typeof exp !== "number" || !Number.isInteger(exp) || exp < 0) return null;
  if (nowSeconds(opts.now ?? Date.now) > exp) return null;
  if (typeof email !== "string") return null;

  if (!opts.normalizeEmail) return { email, exp };
  const normalized = email.toLowerCase().trim();
  return normalized ? { email: normalized, exp } : null;
}

/** The value of one cookie in a `Cookie` request header, or `null` when the header does not carry it. */
export function cookieValue(header: string | null | undefined, name: string): string | null {
  for (const part of (header ?? "").split(";")) {
    const pair = part.trim();
    if (pair.startsWith(`${name}=`)) return pair.slice(name.length + 1);
  }
  return null;
}

/**
 * Reads the account cookie out of a `Cookie` header and verifies it: who the
 * request is from, or `null` when the cookie is absent or does not verify.
 */
export function accountFromCookieHeader(
  header: string | null | undefined,
  secret: string,
  opts: CookieVerifyOptions = {},
): AccountClaims | null {
  const token = cookieValue(header, opts.cookieName ?? DEFAULT_ACCOUNT_COOKIE);
  return token ? verifyAccountToken(token, secret, opts) : null;
}

/**
 * The account cookie's name for a deploy that configures it (the host reads
 * `HECKS_SESSION_COOKIE`): unset or empty means the default, anything else
 * must be a valid cookie name because it is written into a `Set-Cookie`
 * header.
 * @throws {TypeError} when `configured` has characters other than letters, digits, `_`, `-` and `.`
 */
export function resolveAccountCookieName(configured?: string | null): string {
  if (!configured) return DEFAULT_ACCOUNT_COOKIE;
  if (/^[A-Za-z0-9_.-]+$/.test(configured)) return configured;
  throw new TypeError(`${JSON.stringify(configured)} is not a valid cookie name (letters, digits, '_', '-' and '.' only)`);
}
