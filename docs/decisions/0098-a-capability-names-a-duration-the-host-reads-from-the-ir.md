# A capability names a duration, and the host reads it from the IR

**Status:** Accepted. Built (capability contract kind, exporter, Rust host). Date: 2026-10-09. It finishes the number half of the leak ADR 0097 closed for state names: a window the domain decides (how long a link lives, how fresh a webhook must be, how long a seat is held) is declared once in the bluebook, and the Rust host stops carrying its own copy.

## Context

The Rust host holds domain numbers that a bluebook already states or should state:

- `rust/host/src/checkout.rs` `TOLERANCE_SECONDS = 300`, the freshness window of a signed payment-processor webhook. The Checkout package's `webhook.bluebook` already writes the same window as `signed_at.value + 300`.
- `checkout.rs` `SESSION_HOLD_SECONDS = 31 * 60`, the seat hold of a checkout session. `session.bluebook` writes `opened_at.value + 1800`.
- `web/newsletter.rs` `CONFIRM_TTL_SECS` (14 days) and `web/newsletter_send.rs` `UNSUBSCRIBE_TTL_SECS` (730 days), the lifetimes of the emailed confirm and unsubscribe links. ADR 0081 records that one such lifetime had already drifted between two engines.

A renamed or retuned number in the bluebook silently disagrees with the host. The language can fold `days(14)` inside a predicate (ADR 0081), but a host cannot ask a predicate for its constant, and ADR 0097's `mark` names states, not quantities.

## Decision

Add no word. A duration is an attribute that already exists with a `default:` that already reaches the IR, and a capability already names things in the chapter by `"Aggregate.name"` (ADR 0097).

1. **Bluebook side.** The aggregate that owns the rule declares the window as an attribute whose `default:` is whole seconds, typed by a one-field value object like every other number in a bluebook:

   ```ruby
   value_object "Seconds" do
     attribute :value, Integer
   end

   attribute :confirm_window, Seconds, default: { value: 1209600 }   # 14 days
   ```

   The default is the domain's decision. A `given` in the same aggregate may read the same attribute, so the number is written once.
2. **Capability contract.** `Capabilities::CONTRACTS` gains an optional `:duration` kind next to `:mark`. An entry is spelled `Aggregate.attribute`; the builder refuses one that names no attribute of that aggregate, or an attribute whose default is not a positive whole number of seconds (a bare integer, or `{ value: N }`).
   - `provides "newsletter"` gains `confirm_window:` and `unsubscribe_window:`.
   - A new capability `checkout` (resolved like the others, by what a chapter declares) takes `webhook_tolerance:` and `session_hold:`. Both are optional.
3. **IR.** The exporter writes each declared window into the capability fact as a number of seconds (`newsletter.confirm_window`, `checkout.webhook_tolerance`). A chapter that declares none exports exactly what it did before; `checkout` is omitted unless a chapter provides it.
4. **Rust host.** `commerce_ir` reads the seconds from the fact. A window the chapter does not declare takes a labelled `LEGACY_*` default (the values the host held before: 300, 1800, 14 days, 730 days) and logs one warning per window per process. The constants in `checkout.rs`, `newsletter.rs` and `newsletter_send.rs` are deleted.
5. **Grammar and parity.** The new `provides` argument names are rows of the self-hosted grammar (`bluebook.bluebook`), mirrored in the Rust parser's keyword table. No parser logic changes: `default:` and its value-object fill already parse identically in both parsers.

### Where each number lives

| Number | Side | Why |
| --- | --- | --- |
| Confirm link lifetime (14 days) | domain: `Subscriber.confirm_window` | How long a signup stays confirmable is a product rule. |
| Unsubscribe link lifetime (730 days) | domain: `Subscriber.unsubscribe_window` | Same: the promise made to a reader about an old email. |
| Webhook freshness (300 s) | domain: `WebhookReceipt.tolerance` | The Checkout bluebook's `Verify` rule already states it; the host now reads that same attribute. |
| Session seat hold (1800 s) | domain: `CheckoutSession.hold` | How long a guest's seat is held is a rule of the business. |
| Processor's 30-minute minimum expiry (31 min sent) | adapter: `rust/host/src/checkout.rs`, `STRIPE_MIN_HOLD_SECONDS` | A fact about one provider's API. The host raises a shorter domain hold to it (`effective_hold_seconds`); the domain does not know it. |
| Email-provider webhook tolerance (300 s, `web/resend_webhook.rs`) | adapter | The provider's own signing convention for its own webhooks; no bluebook models that webhook, so it stays a labelled provider constant. |

The hecksagon side gets nothing: how a window is turned into a signed token's expiry or a Stripe `expires_at` is wiring.

## Consequences

- Four host constants become four attributes in the bluebooks and four reads from the IR; the legacy defaults go when every shipped Checkout and Newsletter bluebook declares its windows.
- A host that needs a window a domain does not declare still boots, with one warning naming the window; the old behaviour is the default.
- A window is stored on each record (the attribute exists on every `Subscriber` and `WebhookReceipt`). That is honest and cheap, and it means a record can say which window it was created under; it is the cost of reusing `default:` instead of adding a word.
- No grammar logic, IR shape or era changes: only `provides` accepts four more argument names.

## Alternatives considered

- **A new `constant :name, days(14)` word.** Reads best, but adds a word to both parsers, the grammar, the IR and the era text for what an attribute default already carries.
- **A `world` setting.** World settings are deploy-time wiring read by the launcher; a domain rule would leave the bluebook, and the Ruby runtime would not see it.
- **`days()` / `hours()` in `default:`.** Would read better than `1209600` but needs the duration fold to run on attribute defaults in both parsers. Left open: spell the seconds with a trailing comment today.
- **Leave the number in the host and test that it agrees.** A test catches drift after the fact; declaring it once prevents it.

## Open items

- Folding `days()`, `hours()` and `minutes()` inside an attribute `default:`.
- A hecksagon-side override of a window (for example a shorter one in a staging deploy). Nothing needs it yet.
