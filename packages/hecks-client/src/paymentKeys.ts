// What a "paste your two keys and Save" form posts, cleaned up, and the
// sentence a person reads afterwards. Pure on purpose, so it needs no server.
// The keys go to the host once and are never stored, logged or shown again
// here; nothing this file returns (an error, a notice) ever contains what was
// pasted.
//
// Whether a key is well formed for its processor is the host's call: it
// checks the prefixes and that both keys are from the same mode, and answers
// 422 with a message that never quotes a key (see `PaymentsConnection`).

/** The two keys, under the field names the host's `/payments/connection/direct` route reads. */
export interface PastedKeys {
  secret_key: string;
  publishable_key: string;
}

/** Anything that reads a form field by name: a `FormData`, a `Map`, `URLSearchParams`. */
export interface FormFields {
  get(name: string): unknown;
}

/**
 * Reads the pasted `secret_key` and `publishable_key` fields, trimmed, and
 * says in plain words which one is missing when either is. An error never
 * repeats a pasted value.
 */
export function pastedKeys(form: FormFields): { keys: PastedKeys } | { error: string } {
  const secret = String(form.get("secret_key") ?? "").trim();
  const publishable = String(form.get("publishable_key") ?? "").trim();
  if (!secret && !publishable) return { error: "Paste both keys to save them." };
  if (!secret) return { error: "Paste the restricted key as well." };
  if (!publishable) return { error: "Paste the publishable key as well." };
  return { keys: { secret_key: secret, publishable_key: publishable } };
}

/**
 * The confirmation shown after a save: the business's name and the mode, both
 * public facts the host answers with. A missing name reads "your Stripe
 * account"; any mode but `"live"` reads as test.
 */
export function savedMessage(displayName: string | null | undefined, mode: string | null | undefined): string {
  const name = displayName && displayName.trim() ? displayName.trim() : "your Stripe account";
  const label = mode === "live" ? "live" : "test";
  return `Saved. Connected to ${name} in ${label} mode.`;
}
