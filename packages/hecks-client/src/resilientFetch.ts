// Reads JSON from an upstream service that may be briefly down or restarting,
// without turning that into a failure for every caller.
//
// Two layers, in order:
//   1. Retry transient failures (network error, timeout, 502/503/504) a
//      couple of times with a short backoff, enough for a container that is
//      mid-restart.
//   2. If the upstream is still failing (network error or any 5xx), answer
//      with the last successful response for that exact URL from this
//      process's memory, when the caller allows it. A cold process has
//      nothing remembered and still throws, so a genuinely broken deploy is
//      never masked.
// A 4xx is a real answer (bad slug, bad credentials) and is never retried or
// answered from memory.

const DEFAULT_RETRY_DELAYS_MS = [150, 500];
const DEFAULT_ATTEMPT_TIMEOUT_MS = 10_000;
// URLs built from visitor-controlled paths can succeed with an empty answer
// for any input, so the memory is bounded.
const DEFAULT_MAX_REMEMBERED = 200;

/** What `createResilientFetch` needs; every field is optional. */
export interface ResilientFetchConfig {
  /** The fetch to send requests with. Defaults to the global `fetch`, looked up on each call. */
  fetch?: typeof fetch;
  /** Waits `ms` milliseconds between attempts. Defaults to a timer. */
  sleep?: (ms: number) => Promise<void>;
  /** Told when a remembered answer is served instead of a live one. Defaults to `console.warn`. */
  warn?: (message: string) => void;
  /** Waits before each retry, in milliseconds; its length is the number of retries. Defaults to `[150, 500]`. */
  retryDelaysMs?: number[];
  /** How long one attempt may take before it counts as a network failure. Defaults to 10000. */
  attemptTimeoutMs?: number;
  /** How many URLs' last good answers are kept; the least recently answered is dropped first. Defaults to 200. */
  maxRemembered?: number;
}

/** What one `json` call needs to know about the request. */
export interface ResilientRequest {
  /** A human description for error messages, such as `page "about"`. */
  what: string;
  /** The upstream's name or base URL, shown in error messages. */
  source: string;
  /** Answer from memory when the upstream is down. Defaults to true; turn it off where a stale answer would be acted on. */
  allowStale?: boolean;
  /** Resolve to `null` on a 404 instead of throwing. */
  nullOn404?: boolean;
  /** Replaces the configured retry delays for this call. */
  retryDelaysMs?: number[];
  /** Extra request headers, such as a viewer's `Cookie` to read a draft. */
  headers?: Record<string, string>;
  /**
   * The response is for one viewer, read with their credentials: it is never
   * remembered for later requests, and the answer remembered for the same URL
   * (which is public) is never served in its place.
   */
  private?: boolean;
}

/** A read that failed and could not be answered from memory. */
export class ResilientFetchError extends Error {
  constructor(
    message: string,
    /** The last attempt's failure: a network error's message, or `<status> <statusText>`. */
    readonly failure: string,
  ) {
    super(message);
    this.name = "ResilientFetchError";
  }
}

/** A JSON reader with its own memory of last good answers. */
export interface ResilientFetch {
  /**
   * Reads `url` as JSON, retrying transient failures and, when allowed,
   * answering from the last good response for the same URL if the upstream
   * stays down.
   * @throws {ResilientFetchError} when the read fails and nothing may or can be served from memory
   */
  json<T>(url: string, request: ResilientRequest): Promise<T | null>;
  /** Forgets every remembered answer. */
  clear(): void;
}

const timer = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Builds a JSON reader that survives a briefly unavailable upstream. Each
 * reader keeps its own memory, so two readers never share answers.
 */
export function createResilientFetch(config: ResilientFetchConfig = {}): ResilientFetch {
  const sleep = config.sleep ?? timer;
  const warn = config.warn ?? ((message: string) => console.warn(message));
  const attemptTimeoutMs = config.attemptTimeoutMs ?? DEFAULT_ATTEMPT_TIMEOUT_MS;
  const maxRemembered = config.maxRemembered ?? DEFAULT_MAX_REMEMBERED;
  const lastGood = new Map<string, unknown>();

  const remember = (url: string, value: unknown): void => {
    lastGood.delete(url);
    lastGood.set(url, value);
    if (lastGood.size > maxRemembered) lastGood.delete(lastGood.keys().next().value as string);
  };

  return {
    async json<T>(url: string, request: ResilientRequest): Promise<T | null> {
      const { what, source, nullOn404 = false, headers } = request;
      const delays = request.retryDelaysMs ?? config.retryDelaysMs ?? DEFAULT_RETRY_DELAYS_MS;
      const allowStale = (request.allowStale ?? true) && !request.private;
      let failure = "";
      let staleable = false;

      for (let attempt = 0; attempt <= delays.length; attempt++) {
        if (attempt > 0) await sleep(delays[attempt - 1]);

        let res: Response;
        try {
          const send = config.fetch ?? fetch;
          res = await send(url, { headers, signal: AbortSignal.timeout(attemptTimeoutMs) });
        } catch (err) {
          failure = err instanceof Error ? err.message : String(err);
          staleable = true;
          continue;
        }

        if (res.ok) {
          const data = (await res.json()) as T;
          if (!request.private) remember(url, data);
          return data;
        }
        if (res.status === 404 && nullOn404) return null;

        failure = `${res.status} ${res.statusText}`;
        if (res.status >= 500) staleable = true;
        if (![502, 503, 504].includes(res.status)) break;
      }

      if (allowStale && staleable && lastGood.has(url)) {
        warn(`${what}: ${source} unavailable (${failure}); serving last known good`);
        return lastGood.get(url) as T;
      }
      throw new ResilientFetchError(`Failed to fetch ${what} from ${source}: ${failure}`, failure);
    },
    clear: () => lastGood.clear(),
  };
}
