# Open bugs catalog — 2026-08-26

_Every issue from the original 186 has now been investigated live against
current `main` (see
[`2026-08-26-issue-tracker-reconciliation-plan.md`](2026-08-26-issue-tracker-reconciliation-plan.md)
for how the 186 got there) and every remaining question was put to the
user directly for a product decision. **Result: 0 issues open.** All 26
issues that were "confirmed still open, needs a product call" as of the
last update to this doc have since been closed, each with an evidence
comment on its own GitHub issue citing this decision round. This file is
now a record of *why*, not a live worklist._

## The one issue that stayed open briefly, then got closed anyway

| # | What | What happened |
| --- | --- | --- |
| [#145](https://github.com/chrisyoung/hecks/issues/145) | driving-adapter grammar + raw-adapter bug fix | Deliberate future work, per this repo's own survey doc (`docs/hecks-survey-what-we-wish-we-had.md`) — initially left open on purpose as a tracked marker, then closed on explicit follow-up request. If this becomes active work later, file fresh rather than reopening. |

## What got closed, and why (grouped by decision)

**Endorsed as intentional design, not a gap (7 issues)** — #308, #305,
#301, #278 (Transfer/SafeDepositBox source-only guards — the destination
is deliberately checked downstream so the saga's compensation path stays
reachable), #195, #191, #181 (Account/Card validation permissiveness,
each backed by a documented example or guide).

**Investigated closer, confirmed deliberate (1 issue)** — #190
(`CustomerStanding` staying free-form): confirmed live that multiple
production-shaped specs dispatch real prose values like "chargeback
investigation," not enum members — a `one_of` would break them.

**Fixed for real, not rubber-stamped (1 issue)** — #185
(`Pizzas.Order.Purchase` accepting underpayment): the "external fact"
comment justified not re-deciding *whether* a payment happened, but never
justified skipping whether the amount made business sense. Added
`given("the payment covers the price")`. Full suite/rubocop/fuzz clean.

**`redirects_native`, one settled question across 3 tickets (3 issues)**
— #155, #142, #122: feature and its motivating consumer both confirmed
absent from this codebase; the word is documented as deliberately retired.

**Vendored code, no consumer in this repo (4 issues)** — #133, #132,
#131, #130 (AppendLog/DiskBuffer/DreamImage/Stripe adapters): pre-rename
branch content; if wanted later, a fresh issue against real requirements
is the right path, not reopening these.

**Won't-fix — real features, no concrete need driving them (4 issues)**
— #121, #116 (saga leg memory + guards), #153 (entity-query
auto-scoping — would be new, inconsistent DSL semantics), #144
(`HecksagonBuilder` async-verdict stub).

**Superseded by a sibling construct (1 issue)** — #113: `ReadModel` is
the one true place for `count`/`median`/`group_by`; `Query` stays
row-level. Policy's half of this issue was already live (#114).

**Already resolved or no real need (4 issues)** — #136 (real bug fixed
differently/better), #141 (useful part already live, rest has no
semantics per its own text), #139 (no corpus need for a second
classification axis), #112 (premise obsolete — `template()`/
`IR::TemplateSpec` don't exist anywhere in current `lib/`, verified by
reading `Literal.render`, which still deliberately raises on any
unrecognized shape).

## Also fixed this session, unrelated to the 186

Two real bugs surfaced by two independent investigation agents doing
unrelated work, both on `main` before this reconciliation touched them:

- A stale golden IR fixture (`spec/ir_golden_spec.rb`) — regenerated.
- A cross-file constant collision: `spec/bluebook/smoke_test_spec.rb` and
  `spec/bluebook/synthesizer_spec.rb` both booted a real domain literally
  named `"Widget"`, racing on the same dynamically-defined Ruby constant
  depending on random spec order. Renamed `smoke_test_spec.rb`'s domain
  to `"SmokeWidget"`. Verified clean across multiple seeds.

A third, rarer flake was observed once under `parallel_rspec` (the
pre-push hook's runner) but not reliably reproduced despite ~10 further
attempts — no failing spec was ever captured. Left undiagnosed; worth
capturing pre-push hook failure output to a retained log next time it
fires, rather than losing it to a truncated terminal view.
