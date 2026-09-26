// The shapes a host answers with, and the readers that pull typed values out of
// them. Nothing here performs I/O, so it can be imported anywhere, including
// code that runs under a plain `node --test`.

/** A refusal the host reported: the failed rule's kind and the domain's own words for it. */
export interface Refusal {
  kind: string;
  error: string;
}

/**
 * The body of every host answer: the state of the aggregates, keyed
 * `Domain::Aggregate#id`, and the refusals the run reported. `error` is set
 * when the host itself failed rather than the domain refusing.
 */
export interface Answer {
  instances?: Record<string, Record<string, unknown>>;
  refusals?: Refusal[];
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
