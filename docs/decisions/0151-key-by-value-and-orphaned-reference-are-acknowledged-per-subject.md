# key_by_value and orphaned_reference are acknowledged per subject

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-28.

## Context

ADR 0150 gave an aggregate `acknowledges :kind, "reason"`, for `:large_aggregate` only. ADR 0145
read every `key_by_value` and `orphaned_reference` finding over the Hecks domain, found the one
conversion that is sound (`Adr.settles`), and left the others as written-up reasons that the
declarations did not carry. Both kinds are reported once per attribute or once per referenced
aggregate, so one aggregate can hold several findings with different reasons: `PublishingRun`
holds three by-value links, one of them a real gap for a different reason than the other two.

## Decision

1. **The word takes `of:` for the kinds reported once per subject.**
   `acknowledges :key_by_value, "reason", of: :commit` excuses the attribute `commit`.
   `acknowledges :orphaned_reference, "reason", of: :Sweep` excuses the aggregate's references to
   `Sweep`, whichever ending of `Sweep` the check names. An acknowledgement of either kind without
   `of:` is refused when the bluebook is built, and `:large_aggregate` refuses `of:`, since it is
   about the aggregate as a whole.
2. **Aggregate-level and attribute-level are one word.** The aggregate carries the acknowledgement
   and `of:` narrows it, so an acknowledgement of one attribute never excuses another, and a new
   by-value attribute added later is reported until it says why.
3. **The IR carries it.** An acknowledgement emits `{finding:, subject:, reason:}`, with `subject`
   empty text when the kind has none. The language bluebook, the Rust parser's argument table
   (`of`), the reconstruction of a held IR and the Bluebook golden carry the field.
4. **The Hecks and QualityControl domains acknowledge what ADR 0145 left.** Each declaration
   carries the reason ADR 0145 gave: an `Introspection` that holds no records, a `Release` the
   run itself creates, a version or address that is not that aggregate's identity, a `Clearance`
   that exists only once CI has run, a `Sweep` or `Angle` that finishes without ending what cites
   it, and a `Ticket` or `Patch` that mirrors an outside system.
5. **No policy was built.** The test is a referenced record that truly ends, in the same bluebook,
   with no effect outside it. A `Sweep` concluding or an `Angle` being built completes the thing
   the holder cites and does not end the holder; a `Ticket` and a `Patch` are written from what a
   tracker and GitHub report, so a policy that closed them would record a close that did not
   happen there.

## Consequences

- `model_check` reports no `key_by_value` or `orphaned_reference` for the Hecks domain or
  QualityControl. The acknowledgements are the findings' reasons, kept beside the declaration.
- The `Bluebook` language's storage shape gains `subject`: an additive translation edge and a
  ledger move.
- The sentence form and the Ruby renderer still refuse an aggregate that holds an
  acknowledgement.
- An acknowledgement whose attribute or aggregate no longer exists is not reported. A check that
  names such a stale one is a later change.
