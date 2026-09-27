import type { Answer } from "./answer.js";

/** The domain understood the command and said no (a `given` or an invariant failed). */
export class DomainRefusal extends Error {
  constructor(
    readonly kind: string,
    message: string,
  ) {
    super(message);
    this.name = "DomainRefusal";
  }
}

/** The domain could not be reached, or did not answer in the protocol. */
export class DomainUnavailable extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DomainUnavailable";
  }
}

/**
 * The domain's own words for why a command changed nothing: the last refusal
 * the answer carries. Falls back to a generic `NotApplied` refusal when the
 * answer names none.
 */
export function refusalOf(answer: Answer, verb: string): DomainRefusal {
  const refusal = (answer.refusals ?? []).at(-1);
  return new DomainRefusal(refusal?.kind ?? "NotApplied", refusal?.error ?? `the domain did not apply ${verb}`);
}
