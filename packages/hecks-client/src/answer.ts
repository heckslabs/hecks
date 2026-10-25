// The shapes a host answers with, and the readers that pull typed values out of
// them. Nothing here performs I/O, so it can be imported anywhere, including
// code that runs under a plain `node --test`.

import { DomainRefusal } from "./errors.js";

/** A refusal the host reported: the failed rule's kind and the domain's own words for it. */
export interface Refusal {
  verb?: string;
  kind: string;
  error: string;
}

/** One reason a command would be refused, as a validation reports it. */
export interface ValidationRefusal {
  /** What sort of no: `refused`, `not_found`, `unauthorized` or `absent_argument`. */
  kind: string;
  /** The point of dispatch it came from: `arguments`, `role`, `references`, `state`, `givens`, `ensures`, `invariants`. */
  stage: string;
  /** The refusal class the domain raises (`GivenNotMet`), when the host names it. */
  refusal?: string | null;
  /** The domain's own words for why. */
  message: string | null;
  /** The attribute it is about, when the host knows (the Ruby runtime does; the Rust host does not yet). */
  attribute?: string | null;
  /** A JSON Pointer to the offending value, when the host knows. */
  path?: string | null;
  /** The text of the rule that refused, when the host knows. */
  rule?: string | null;
}

/**
 * Whether a command would be accepted right now and, if not, why. Advisory: the state it was judged
 * on can change before the real dispatch, which stays authoritative. The Rust host stops at the
 * first refusal, so `refusals` holds at most one there.
 */
export interface Validation {
  ok: boolean;
  refusals: ValidationRefusal[];
}

/**
 * The body of every host answer: the state of the aggregates, keyed
 * `Domain::Aggregate#id`, and the refusals the run reported. `error` is set
 * when the host itself failed rather than the domain refusing.
 */
export interface Answer {
  instances?: Record<string, Record<string, unknown>>;
  refusals?: Refusal[];
  /** One entry per question asked with `HostClient#query`. */
  queries?: QueryResult[];
  error?: string;
  /** Set on the answer to a validation (`HostClient#validate`). */
  ok?: boolean;
}

/**
 * What the host answered to one declared query: its rows (each a state, keyed
 * by attribute), or `null` rows and the reason in `error` when it refused.
 */
export interface QueryResult {
  query: string;
  args?: Record<string, unknown>;
  rows: Record<string, unknown>[] | null;
  error?: string;
}

/**
 * The states of one aggregate in an answer, as `[id, state]` pairs. The
 * aggregate is named in full (`Domain::Aggregate`), the way it appears in the
 * answer's keys.
 */
export function instancesOf(answer: Answer, aggregate: string): [string, Record<string, unknown>][] {
  const prefix = `${aggregate}#`;
  return Object.entries(answer.instances ?? {})
    .filter(([key]) => key.startsWith(prefix))
    .map(([key, state]) => [key.slice(prefix.length), state]);
}

// A value object arrives as {value: "x"} or {cents: 900}; a plain value passes
// through, so a wrapped and a flattened answer read the same.
function scalar(raw: unknown, key: string): unknown {
  if (raw && typeof raw === "object" && key in raw) return (raw as Record<string, unknown>)[key];
  return raw;
}

/** A string value object's text, or null when it is absent or empty. */
export const text = (raw: unknown): string | null => {
  const v = scalar(raw, "value");
  return typeof v === "string" && v !== "" ? v : null;
};

/** A numeric value object's number under `key` ("value", "cents"), 0 when absent. */
export const whole = (raw: unknown, key: string): number => {
  const v = scalar(raw, key);
  return typeof v === "number" ? v : Number(v ?? 0);
};

/** A numeric value object's number under `key`, or null when it is absent (an optional attribute left unset). */
export const optionalWhole = (raw: unknown, key: string): number | null => {
  const v = scalar(raw, key);
  return v === null || v === undefined || v === "" ? null : Number(v);
};

/**
 * The rows a query answered, or `null` when the answer has no entry for it.
 * With `name` the entry is the one asked as that question (bare or qualified);
 * without, the last entry.
 * @throws {DomainRefusal} when the host refused the question (an unknown query, or one answered outside the domain)
 */
export function rowsOf(answer: Answer, name?: string): Record<string, unknown>[] | null {
  const entries = answer.queries ?? [];
  const short = (question: string) => question.replace(/^.*::/, "");
  const entry = name === undefined ? entries.at(-1) : entries.find((candidate) => short(candidate.query) === short(name));
  if (!entry) return null;
  if (entry.rows === null || entry.rows === undefined) {
    const refusal = (answer.refusals ?? []).find((candidate) => short(candidate.verb ?? "") === short(entry.query));
    throw new DomainRefusal(refusal?.kind ?? "QueryRefused", entry.error ?? `the host did not answer ${entry.query}`);
  }
  return entry.rows;
}
