// A client for the payment-connection JSON API a Hecks host answers under
// `/payments/connection` (rust/host/src/payments.rs). The routes:
//
//   GET  /payments/connection             the connection as `PaymentConnectionState`
//   POST /payments/connection/direct      connect the business's own account
//                                         ({secret_key, publishable_key}, or {mode})
//   POST /payments/connection/disconnect  disconnect (or pause, once enabled)
//   POST /payments/connection/enable      turn real payments on   (operator only)
//   POST /payments/connection/disable     turn real payments off  (operator only)
//
// Every route acts as the person behind the account cookie, so each call
// forwards that person's own session: the host decides who may connect the
// account (an Owner) and who may turn real payments on (the platform
// operator). Nothing here stores or logs a key; the connection the host
// answers with holds only public facts about the account.
//
// Like the dispatch protocol, this is for server-to-server calls, never for a
// browser.

import { DEFAULT_ACCOUNT_COOKIE } from "./accountToken.js";
import { DomainUnavailable } from "./errors.js";
import type { PastedKeys } from "./paymentKeys.js";

const DEFAULT_TIMEOUT_MS = 8000;
const CONNECTION_PATH = "/payments/connection";

export type PaymentMode = "test" | "live";

export type PaymentStatus = "not_connected" | "connected" | "enabled" | "paused" | "disconnected";

/** What the host says about the business's payment connection. It never carries a credential. */
export interface PaymentConnectionState {
  status: PaymentStatus;
  /** The processor's key, such as `"stripe"`; `null` while nothing is connected. */
  processor: string | null;
  /** The processor's display name, such as `"Stripe"`. */
  label: string | null;
  account_ref: string | null;
  mode: PaymentMode | null;
  /** The business's name at the processor, when it has one. */
  display_name: string | null;
  /** Modes in which the business's own account has keys on the host. */
  direct_modes: PaymentMode[];
  /** Whether the current connection uses the business's own account. */
  direct: boolean;
  /** Whether the host can keep keys pasted into a form (so the form is worth showing). */
  can_save_keys: boolean;
  /** Whether the caller may connect and disconnect the account. */
  can_manage: boolean;
  /** Whether the caller may turn real payments on and off. */
  can_enable: boolean;
  /** Always empty on this host; kept so a page that still reads the list renders. */
  adapters?: unknown[];
}

/**
 * The outcome of one call. A `200` with a connection is `ok`. Anything else
 * (`401` not logged in, `403` not permitted, `409` wrong state, `422` refused
 * or malformed keys, ...) carries the host's own words in `error` when it sent
 * JSON with one, and `undefined` when it did not, which is what an older host
 * without these routes does by redirecting to an HTML login page.
 */
export type PaymentsResult =
  | { ok: true; status: number; connection: PaymentConnectionState }
  | { ok: false; status: number; error: string | undefined };

/** What a `PaymentsConnection` needs to reach a host. */
export interface PaymentsConnectionOptions {
  /** Where the host listens ("http://127.0.0.1:4322"). Trailing slashes are trimmed. Required. */
  url: string;
  /** The name of the cookie the host reads the account token from. Defaults to `hecks_session`, the host's own default. */
  cookieName?: string;
  /** How long one request may take before it counts as unreachable. Defaults to 8000. */
  timeoutMs?: number;
  /** The fetch to send requests with. Defaults to the global `fetch`, looked up on each call. */
  fetch?: typeof fetch;
}

/** Talks to one host's payment-connection routes on behalf of one signed-in person per call. */
export class PaymentsConnection {
  /** The host's base URL, without a trailing slash. */
  readonly url: string;
  /** The cookie name the account token is sent under. */
  readonly cookieName: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch | undefined;

  constructor(options: PaymentsConnectionOptions) {
    if (!options?.url) throw new TypeError("PaymentsConnection needs the host's `url`");
    this.url = options.url.replace(/\/+$/, "");
    this.cookieName = options.cookieName ?? DEFAULT_ACCOUNT_COOKIE;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.fetchImpl = options.fetch;
  }

  /** The connection as the host describes it. Readable by an Owner or the operator. */
  show(session: string): Promise<PaymentsResult> {
    return this.call(session, "GET", "");
  }

  /**
   * Saves two pasted keys and connects the business's own account. The host
   * checks them with the processor, so this can take a few seconds. Owner only.
   */
  saveKeys(session: string, keys: PastedKeys): Promise<PaymentsResult> {
    return this.call(session, "POST", "/direct", keys);
  }

  /** Connects the business's own account using keys already set on the host, for `mode`. Owner only. */
  useOwnAccount(session: string, mode: PaymentMode): Promise<PaymentsResult> {
    return this.call(session, "POST", "/direct", { mode });
  }

  /** Disconnects the account; once payments are enabled, pauses registrations instead. Owner only. */
  disconnect(session: string): Promise<PaymentsResult> {
    return this.call(session, "POST", "/disconnect", {});
  }

  /** Turns real payments on for the connected account. Platform operator only. */
  enable(session: string): Promise<PaymentsResult> {
    return this.call(session, "POST", "/enable", {});
  }

  /** Turns real payments off. Platform operator only. */
  disable(session: string): Promise<PaymentsResult> {
    return this.call(session, "POST", "/disable", {});
  }

  private async call(session: string, method: "GET" | "POST", path: string, body?: unknown): Promise<PaymentsResult> {
    // A session is one cookie value; anything that could end it early or
    // start another header is refused rather than sent.
    if (!session || /[\s;,"\\]/.test(session)) throw new TypeError("PaymentsConnection needs the account cookie's value as `session`");
    const send = this.fetchImpl ?? globalThis.fetch;
    let res: Response;
    try {
      res = await send(`${this.url}${CONNECTION_PATH}${path}`, {
        method,
        headers: { "Content-Type": "application/json", Cookie: `${this.cookieName}=${session}` },
        body: body === undefined ? undefined : JSON.stringify(body),
        // An older host has no such route and redirects to an HTML login page.
        redirect: "manual",
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (err) {
      throw new DomainUnavailable(`could not reach the host at ${this.url}: ${err}`);
    }

    const isJson = (res.headers.get("content-type") ?? "").includes("application/json");
    const parsed: unknown = isJson ? await res.json().catch(() => null) : null;
    const fields = parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : null;
    if (res.status === 200 && fields && typeof fields.status === "string") {
      return { ok: true, status: res.status, connection: fields as unknown as PaymentConnectionState };
    }
    return { ok: false, status: res.status, error: typeof fields?.error === "string" ? fields.error : undefined };
  }
}
