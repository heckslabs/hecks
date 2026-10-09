# A capability names a word and a field, and the host keeps only the adapter's own vocabulary

**Status:** Accepted. Built for the failure reason and the registration timestamp; the port-outcome declaration is a documented follow-up. Date: 2026-10-09. It continues ADR 0097 (marks name states) and ADR 0098 (durations name quantities): this one decides, leak by leak, which side of the seam each remaining host literal lives on, and moves only what is domain.

## Context

Four more literals in `rust/host` look like domain vocabulary baked into the adapter:

1. `web/registrations.rs`: the Stripe webhook handler maps `checkout.session.expired` to the payment's failure verb with the reason `checkout_expired`, and the local mock-checkout route takes `outcome=succeeded|failed`.
2. `payments.rs`: the host writes `processor: "stripe"` into the connection command and hardcodes the modes `test` and `live`.
3. `web.rs` `registration_list_rows`: a list of four guessed timestamp attributes (`created_at`, `registered_at`, `requested_at`, `occurred_at`).
4. `resend.rs`: the mock mailer refuses the address `bounce@example.com` with the reason `bounced`.

## Decision: where each one lives

| Literal | Side | What changes |
| --- | --- | --- |
| Provider event names (`checkout.session.completed`, `checkout.session.expired`) | adapter (host / hecksagon) | Nothing. They are the processor's wire vocabulary. |
| Failure reason a lapsed hold records (`checkout_expired`) | domain | The Payments chapter declares it: `provides "payments", lapse_reason: "Payment.lapse_reason"`, the string `default:` of an attribute. The `payments` fact carries it; the host reads it, with a labelled `LEGACY_LAPSE_REASON` default and one warning. |
| `outcome=succeeded|failed` on the local mock-checkout route, and its `declined_at_local_checkout` reason | adapter | Nothing. They are the mock processor's own report and its own words for a decline made on the local simulator. The domain verbs they dispatch are already read from `provides "payments"` (`succeeded`, `failed`). |
| `processor: "stripe"` | adapter | The host module is the Stripe adapter, so the processor it reports is its own name. It becomes the named constant `PROCESSOR`. The domain's `Processor` value object enumerates the words it admits, and a test now holds the adapter's word to that list. |
| Modes `test`, `live` | adapter | They name a Stripe account's two key environments (`sk_test_`, `sk_live_`). The constant stays, documented, and the same test holds it to the domain's `ConnectionMode` list, so the two cannot drift silently. |
| Which registration attribute holds the timestamp | domain | `provides "registrations", registered_at: "Registration.requested_at"` names it. The `registrations` fact carries the attribute name; the host reads it, with a labelled `LEGACY_REGISTERED_AT` guess list and one warning. |
| `ir.rs` `conventional(domain)` names (`Event`, `Registration`, ...) | unchanged | A declaration already replaces the guess (`provides "registrations"`, `provides "payment_connection"`); the conventional names are what a host with no IR loaded uses. No declaration can replace them, so they stay. |
| Mock refusal vocabulary (`bounce@example.com`, `bounced`) | follow-up | See below. |

### Two more optional capability kinds

ADR 0098 added `:duration`. The two items above need a word and a field name, not a quantity, so `Capabilities::CONTRACTS` gains two optional kinds, both spelled `Aggregate.attribute` and both refused at build time when the attribute is absent:

- `:text` resolves to the attribute's string `default:`, bare or as the `{ value: "..." }` fill of a one-field value object. The exporter writes the string into the capability fact.
- `:attribute` resolves to the attribute's own name, so the host can read a stored field by a name the domain chose rather than one it guessed.

No grammar logic changes: `lapse_reason:` and `registered_at:` are two more rows of the `provides` argument table, mirrored in the Rust parser's keyword table. A chapter that declares neither exports exactly what it did before.

## Follow-up: a port declares its outcomes once

The email mock lives in `rust/host/src/resend.rs`; no Ruby mock mailer exists in this repository (the shipped bluebooks' Ruby side carries its own). Each runtime therefore keeps its own copy of "which address the mock refuses and what it says". The fix is a port-operation outcome declaration in the hecksagon, for example a `deliver` operation listing `bounced` among its refusals and naming the address the mock refuses, which both the Rust mock and any Ruby mock read.

No such mechanism exists today: a port operation declares its arguments and the event it emits, not its outcomes, and adding outcomes means a new hecksagon word, its grammar rows, both parsers, the exporter and the IR. That is larger than the pattern of ADRs 0097 and 0098, so it is left as a decision to take on its own. Until then the Rust mock's address and reason stay constants whose comment points here, and `the_mock_logs_instead_of_sending_and_bounces_the_test_address` keeps them stable.

## Consequences

- Two host literals become two bluebook declarations and two reads from the IR; the legacy defaults go when every shipped Payments and registrations bluebook declares them.
- A host reading a bluebook that predates the declarations still boots, with one warning naming the missing entry.
- The attribute a `:text` entry names exists on every record of its aggregate (`Payment.lapse_reason` is stored on each payment), the same cost ADR 0098 accepted for durations.
- The processor and mode words stay in the host; a test, not a mechanism, keeps them in step with the domain.

## Alternatives considered

- **Declare the processor in the capability too.** The adapter is the one thing that knows which processor it is; a domain naming it would make the domain choose the adapter's identity, the reverse of the seam.
- **Read the admitted modes from the IR.** Possible, but the host also reads Stripe keys per mode from the environment, so the list of modes is a fact about Stripe, not only about the domain. A test holding the two together is enough.
- **Pick the timestamp by type.** Guessing by type is still a guess; a name the domain gave is not.
