// A client for the body-shaped dispatch protocol a Hecks host answers. Two
// request shapes, both posted to `<url>/dispatch`:
//
//   { "read": true }
//     -> { instances: { "Domain::Aggregate#<id>": { ...state } }, refusals: [] }
//   { "verb": "Domain::Aggregate.Verb", "to": "<id>", "with": { ... }, "role": "Role" }
//     -> the same shape after the command ran
//
// The host answers HTTP 200 whether or not the domain refused, and its
// `refusals` list can carry entries replayed from history, so a command is
// judged by the state that comes back (see `HostClient#apply`), never by the
// list alone.
//
// The protocol carries no authentication. It is meant for server-to-server
// calls on a private network, never for a browser.

import { refusalOf, DomainUnavailable } from "./errors.js";
import type { Answer } from "./answer.js";
import { instancesOf } from "./answer.js";

const DEFAULT_TIMEOUT_MS = 8000;

/** What a `HostClient` needs to reach one domain. */
export interface ClientOptions {
  /** The domain's name as its bluebook declares it ("Shop"). Falls back to the `HECKS_DOMAIN` environment variable. */
  domain?: string;
  /** Where the host listens ("http://127.0.0.1:4322"). Falls back to the `HECKS_SERVICE_URL` environment variable. */
  url?: string;
  /**
   * The role sent with every command unless a call names its own. The host
   * compares it as a plain string against the roles a command declares; when
   * neither this nor the call sets one, no role is sent and the host performs
   * no role check.
   */
  role?: string;
  /** How long one request may take before it counts as unreachable. Defaults to 8000. */
  timeoutMs?: number;
  /** The fetch to send requests with. Defaults to the global `fetch`, looked up on each call. */
  fetch?: typeof fetch;
}

/**
 * One command whose outcome is judged from the state that comes back.
 * `parse` turns the answer into the caller's own shape and `confirm` says
 * whether that shape shows the command took effect.
 */
export interface Command<T> {
  /** The verb, `Aggregate.Verb` or fully qualified (`Domain::Aggregate.Verb`). */
  verb: string;
  with: Record<string, unknown>;
  /** The target instance id; absent for a command that creates one. */
  to?: string;
  role?: string;
  parse: (answer: Answer) => T;
  confirm: (parsed: T) => boolean;
}

const fromEnv = (name: string): string | undefined => {
  const value = typeof process === "undefined" ? undefined : process.env?.[name];
  return value ? value : undefined;
};

/** Talks to one domain on one host. */
export class HostClient {
  /** The domain's name, as configured. */
  readonly domain: string;
  /** The host's base URL, without a trailing slash. */
  readonly url: string;
  private readonly role: string | undefined;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch | undefined;

  constructor(options: ClientOptions = {}) {
    const domain = options.domain ?? fromEnv("HECKS_DOMAIN");
    const url = options.url ?? fromEnv("HECKS_SERVICE_URL");
    if (!domain) throw new TypeError("HostClient needs a domain: pass `domain` or set HECKS_DOMAIN");
    if (!url) throw new TypeError("HostClient needs a service URL: pass `url` or set HECKS_SERVICE_URL");
    this.domain = domain;
    this.url = url.replace(/\/+$/, "");
    this.role = options.role;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.fetchImpl = options.fetch;
  }

  /** A name in full: one that already carries `::` is left alone, any other is placed in this client's domain. */
  qualify(name: string): string {
    return name.includes("::") ? name : `${this.domain}::${name}`;
  }

  /** The states of one aggregate in an answer, as `[id, state]` pairs. `aggregate` may be bare ("Event") or qualified. */
  instancesOf(answer: Answer, aggregate: string): [string, Record<string, unknown>][] {
    return instancesOf(answer, this.qualify(aggregate));
  }

  /** Everything the domain holds, as the protocol answers it. */
  read(): Promise<Answer> {
    return this.post({ read: true });
  }

  /**
   * Sends one command and returns the raw answer. Callers judge the outcome
   * from the state in it and turn a miss into a refusal with `refusalOf`.
   */
  dispatch(verb: string, args: Record<string, unknown> = {}, to?: string, role?: string): Promise<Answer> {
    const asRole = role ?? this.role;
    return this.post({ verb: this.qualify(verb), ...(to ? { to } : {}), with: args, ...(asRole ? { role: asRole } : {}) });
  }

  /**
   * Runs one command and returns what `command.parse` reads from the answer.
   * Throws `DomainRefusal` when that state does not show the change,
   * carrying the domain's own words for why.
   */
  async apply<T>(command: Command<T>): Promise<T> {
    const answer = await this.dispatch(command.verb, command.with, command.to, command.role);
    const parsed = command.parse(answer);
    if (command.confirm(parsed)) return parsed;
    throw refusalOf(answer, command.verb);
  }

  private async post(body: Record<string, unknown>): Promise<Answer> {
    const send = this.fetchImpl ?? globalThis.fetch;
    let res: Response;
    try {
      res = await send(`${this.url}/dispatch`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (err) {
      throw new DomainUnavailable(`could not reach the domain at ${this.url}: ${err}`);
    }
    if (!res.ok) throw new DomainUnavailable(`the domain answered HTTP ${res.status}`);

    let answer: Answer;
    try {
      answer = (await res.json()) as Answer;
    } catch {
      throw new DomainUnavailable("the domain did not answer with JSON");
    }
    if (answer.error) throw new DomainUnavailable(answer.error);
    return answer;
  }
}

/** Shorthand for `new HostClient(options)`. */
export const createClient = (options: ClientOptions = {}): HostClient => new HostClient(options);
