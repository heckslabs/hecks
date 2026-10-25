// A client for the body-shaped dispatch protocol a Hecks host answers. Two
// request shapes, both posted to `<url>/dispatch`:
//
//   { "read": true }
//     -> { instances: { "Domain::Aggregate#<id>": { ...state } }, refusals: [] }
//   { "query": "Domain::Aggregate.Query", "args": { ... } }
//     -> { queries: [{ query, rows, error? }], refusals: [] }, nothing written
//   { "verb": "Domain::Aggregate.Verb", "to": "<id>", "with": { ... },
//     "role": "Role", "actor_id": "<id>" }
//     -> the same shape after the command ran
//
// Every request also carries `"bare": true` unless the client was built with
// `bare: false`: the host then answers a value object that has one field as
// that field's own value (`name: "Margherita"`, not `name: { value: "Margherita" }`),
// the same shape a command takes it in. Without it the host answers the shape
// it stores.
//
// The host answers HTTP 200 whether or not the domain refused, and its
// `refusals` list can carry entries replayed from history, so a command is
// judged by the state that comes back (see `HostClient#apply`), never by the
// list alone.
//
// An identified caller passes `actorId`, the Governance identity id of the
// signed-in person, and leaves `role` unset: the host then checks the roles
// Governance has assigned to that actor. A stated `role` is a label the
// caller writes, not a proof. The host honors `actor_id` only on its
// internal protocol, from its own peers.
//
// The protocol carries no authentication of its own, and since hecks 2.8.0 the
// host accepts it only from a peer on the same machine; any other address gets
// the web layer's answer. This client works from the host's own machine, never
// across a network and never from a browser. It sends no session cookie or
// token.

import { refusalOf, DomainUnavailable } from "./errors.js";
import type { Answer, Validation, ValidationRefusal } from "./answer.js";
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
  /**
   * The Governance identity id of the person on whose behalf commands run,
   * sent as `actor_id` with every command unless a call names its own. Pass
   * it for an identified caller and leave `role` unset, so Governance's role
   * assignments decide. The host honors it only on its internal protocol.
   */
  actorId?: string;
  /** How long one request may take before it counts as unreachable. Defaults to 8000. */
  timeoutMs?: number;
  /** The fetch to send requests with. Defaults to the global `fetch`, looked up on each call. */
  fetch?: typeof fetch;
  /**
   * Whether the host answers a single-field value object as its bare value. Defaults to true;
   * false asks for the wrapped shape the host stores (`{ value: "x" }`, `{ cents: 900 }`).
   */
  bare?: boolean;
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
  /** The Governance identity id of the caller; see `ClientOptions.actorId`. */
  actorId?: string;
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
  private readonly actorId: string | undefined;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch | undefined;
  private readonly bare: boolean;

  constructor(options: ClientOptions = {}) {
    const domain = options.domain ?? fromEnv("HECKS_DOMAIN");
    const url = options.url ?? fromEnv("HECKS_SERVICE_URL");
    if (!domain) throw new TypeError("HostClient needs a domain: pass `domain` or set HECKS_DOMAIN");
    if (!url) throw new TypeError("HostClient needs a service URL: pass `url` or set HECKS_SERVICE_URL");
    this.domain = domain;
    this.url = url.replace(/\/+$/, "");
    this.role = options.role;
    this.actorId = options.actorId;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.fetchImpl = options.fetch;
    this.bare = options.bare ?? true;
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
  dispatch(verb: string, args: Record<string, unknown> = {}, to?: string, role?: string, actorId?: string): Promise<Answer> {
    return this.post(this.commandBody(verb, args, to, role, actorId));
  }

  /**
   * Asks whether a command would be accepted right now, and if not, why. The host runs the command
   * as far as it can and keeps nothing: no write, no reaction. It answers HTTP 200 whether or not
   * the command would be refused, so this resolves with the verdict and never throws a
   * `DomainRefusal`; `DomainUnavailable` still means the host could not be reached.
   */
  async validate(verb: string, args: Record<string, unknown> = {}, to?: string, role?: string, actorId?: string): Promise<Validation> {
    const answer = await this.post({ ...this.commandBody(verb, args, to, role, actorId), dry_run: true });
    return { ok: answer.ok === true, refusals: (answer.refusals ?? []) as unknown as ValidationRefusal[] };
  }

  /**
   * The JSON Schema of the facts one command takes (`Aggregate.Command`, bare or qualified), for
   * checking a payload before asking the host. A schema cannot hold a rule over stored state, so
   * those ride along as `x-` annotations; `validate` stays the authority. Throws
   * `DomainUnavailable` when the host cannot be reached or has no schema for the command.
   */
  async schema(verb: string): Promise<Record<string, unknown>> {
    const [domain, rest] = this.qualify(verb).split("::");
    const [aggregate, command] = rest.split(".");
    const send = this.fetchImpl ?? globalThis.fetch;
    let res: Response;
    try {
      res = await send(`${this.url}/${domain}/${aggregate}/${command}.json?schema=1`, { signal: AbortSignal.timeout(this.timeoutMs) });
    } catch (err) {
      throw new DomainUnavailable(`could not reach the domain at ${this.url}: ${err}`);
    }
    if (!res.ok) throw new DomainUnavailable(`the domain answered HTTP ${res.status} for the schema of ${verb}`);
    try {
      return (await res.json()) as Record<string, unknown>;
    } catch {
      throw new DomainUnavailable("the domain did not answer with JSON");
    }
  }

  private commandBody(verb: string, args: Record<string, unknown>, to?: string, role?: string, actorId?: string): Record<string, unknown> {
    const asRole = role ?? this.role;
    const asActor = actorId ?? this.actorId;
    return {
      verb: this.qualify(verb),
      ...(to ? { to } : {}),
      with: args,
      ...(asRole ? { role: asRole } : {}),
      ...(asActor ? { actor_id: asActor } : {}),
    };
  }

  /**
   * Asks one declared query (`Aggregate.Query`, bare or qualified) and returns the raw answer.
   * The host reads current state and writes nothing; the rows are in `answer.queries`, which
   * `rowsOf` reads (and which throws when the host refused the question).
   */
  query(name: string, args: Record<string, unknown> = {}): Promise<Answer> {
    return this.post({ query: this.qualify(name), args });
  }

  /**
   * Runs one command and returns what `command.parse` reads from the answer.
   * Throws `DomainRefusal` when that state does not show the change,
   * carrying the domain's own words for why.
   */
  async apply<T>(command: Command<T>): Promise<T> {
    const answer = await this.dispatch(command.verb, command.with, command.to, command.role, command.actorId);
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
        body: JSON.stringify(this.bare ? { ...body, bare: true } : body),
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
