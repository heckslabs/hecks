# Lifecycle states carry marks, and the host reads them from the IR

**Status:** Accepted. Lifecycle `mark` is built (Ruby builder, grammar, IR, Rust parser); the capability half is built too. Date: 2026-10-09. A lifecycle can say which of its states mean something to a reader outside the domain (holds a seat, is a failure, is confirmed), so the Rust host and the launcher stop carrying those lists as constants.

## Context

A scan of the host and the bluebooks found the same defect in several places: domain meaning that lives in the adapter because the bluebook has no way to say it.

- `rust/host/src/web/registrations.rs` computes seats left from `SEAT_HOLDING_PAYMENT_STATUSES`, a hardcoded list of Payment states.
- `rust/host/src/web/newsletter.rs` and `newsletter_send.rs` select subscribers by the strings `"pending"`, `"confirmed"` and `"unsubscribed"`.
- `hecks.world` holds `failure_states`, the lifecycle states `--wait` reports as a failure. `docs/plans/3.0/FOLLOWUP-domain-leaks.md` already says this belongs on the lifecycle.

A lifecycle names its states and transitions, but it cannot say what a state means to a reader. A `query` can filter on a status, but a host that wants "the states that hold a seat" cannot ask a query for a list of states. So the list is copied into Rust, where the Ruby runtime, the generators and the conformance corpus cannot see it, and where a renamed state silently breaks it.

## Decision

1. **Bluebook side.** Add one word to the `Lifecycle` grammar: `mark`. It names a meaning and the states that carry it.

   ```ruby
   lifecycle :status, default: "pending" do
     mark :holds_seat, "pending", "succeeded", "refunding", "disputed"
     transition "Succeed" => "succeeded", from: "pending"
   end
   ```

   A mark is a domain fact: "these states hold a seat". It is checked like the rest of the lifecycle: every state named must exist as the default or a transition target, and a mark name is a lowercase word.
2. **IR.** Each lifecycle in `ir.json` gains `marks: { "holds_seat": ["pending", ...] }`, omitted when empty. Existing IR is unchanged for lifecycles with no marks, so no era needs re-minting for domains that do not use the word.
3. **Capability contract.** A capability may name the marks a host needs from its aggregate, the same declared-not-named shape the verbs already have. The Ruby `Capabilities::CONTRACTS` gains a `:mark` kind next to `:command`, `:query` and `:port_operation`; the Rust binding reads the state list from the IR through that declared name, not by chapter or aggregate name.

   Built: `provides "payments", ..., holds_seat: "Payment.holds_seat"` (spelled `Aggregate.mark_name`) is an optional `:mark` entry; it must name a mark on that aggregate's lifecycle, and the `payments` fact in `ir.json` carries `holds_seat: [states]` when declared. The host keeps `LEGACY_HOLDS_SEAT` as a labelled fallback until the Payments package declares the mark.
4. **Hecksagon side.** Nothing. How a host turns a state list into a seat count (a scan of `dispatch::read` instances) stays an adapter.
5. **Ruby and Rust parity.** Both parsers accept `mark`; the neutral conformance corpus gets a fixture whose expected output includes the marks, so the two cannot drift.

## Consequences

- The seat-holding rule, the newsletter audience and the `--wait` failure states each become one `mark` line in the bluebook, and the matching Rust constants and the `failure_states` world setting are deleted.
- A host that needs a state meaning a domain does not mark gets a clear boot refusal, not a silent empty list.
- This is a language change: it touches the lifecycle builder, the grammar (`syntax.bluebook`), the IR writer, both parsers and the docs, and ships in one release (see the release rule: the maintainer decides when).

## Alternatives considered

- **A named query in the capability contract.** No grammar change, but a query returns instances, not a list of states, and `where` is an equality filter. The host would run the query and re-derive the states, which is the same logic in a different place.
- **Hardcode the list in the hecksagon.** Moves the leak across the line instead of closing it: "pending holds a seat" is a fact about Payment, not about wiring.
- **A boolean flag per state (`state "pending", holds_seat: true`).** Adds a free-form key per meaning to every state row; a mark names a meaning once and lists its states.

## Open items

- Decided: marks are allowed on any lifecycle, so `failure_states` and ad-hoc readers can use it.
- Whether the checker should warn when a mark names every state (it then marks nothing).
- The exact grammar-era handling: frozen era text is read as it is today; the new word is available from the next era.
