# `LeaseClock` — retention note

**Kept.** Targets the differential fuzz harness's own no-clock premise:
`spec/rust_conformance_fuzz_spec.rb` (and every stress domain's own
out-of-band `bin/rust_conformance_fuzz` run) generates ONE sequence and
replays it through both Ruby and a compiled Rust binary, then diffs the
two — which only means anything if both engines are deterministic
FUNCTIONS of that sequence. Neither runtime reads a wall clock at
dispatch time at all (grepped: no `Time.now`/`Clock`/`SystemTime`
anywhere under `lib/hecks/runtime` or `rust/src/kernel`); the corpus's
own established idiom for "now" is `qa/bluebook/quality_control.
bluebook`'s `Instant` value object plus `Target.Claim`'s own comment,
quoted in the bluebook's header: "`now` ARRIVES AS AN ARGUMENT, from the
Clock port. A predicate cannot ask the time — it reads attributes and
nothing else — so the caller supplies it, exactly as it supplies an id."
That domain is Memory-only (`Hecks::Codemod`'s isolation guard) and has
never once run through `bin/project_rust` or a differential fuzz spec —
the identical construct has never been checked on the one engine that
would actually notice a hidden wall-clock read. `LeaseClock` is that
port: the same "clock as data" idiom, minimal, generated to Rust and
fuzzed against it for the first time.

## What was checked before authoring this

- `grep -rn "now\|Instant\|expires\|lease\|ttl" examples/ qa/stress_domains/*/bluebook` —
  every hit is either incidental prose ("now ALSO", "now DEREFERENCES")
  or a STATIC field never compared to anything (payment card expiry
  dates). No bluebook under `examples/` or `qa/stress_domains/` declares
  an Integer value object read as a point in time and compared, via
  `given` or `where`, against a stored Integer field of the same kind.
- The one two-Integer-attribute `given` anywhere in the differentially-
  fuzzed corpus (`examples/banking/bluebook/transfers_and_payments.
  bluebook:412`, `attempts.value < max_attempts.value`) compares a
  counter against another counter, not a clock reading against a
  recorded one.
- `bin/qa_domain_novelty qa/stress_domains/lease_clock --against <every
  example and stress domain, by path>` (avoiding a live ledger boot,
  per this PR's own scope — see "Not done here" below) reports **no new
  pair**, honestly: this domain's own properties (`lifecycle`,
  `has_query`, `has_default`) are each already paired with each other
  by existing targets (banking alone saturates them). `Hecks::Fuzzing::
  FormCensus` has no entry at all for "an explicit Integer clock
  argument compared against a stored Integer field" — the exact "name
  the form before the gate can see it" gap `referral_chain`'s own
  NOTES.md hit first. This PR does not add one: `FormCensus`'s two
  consumers (`spec/combination_coverage_spec.rb`'s golden corpus and
  this gate) are deliberately kept from drifting from each other, and a
  new form's golden-corpus fixture is a bigger, separate change than
  this domain's own scope. The manual grep above is this domain's real
  novelty argument, the same shape `tenant_ledger`'s own NOTES.md
  used (its own real novelty argument — two independently tenant-scoped
  aggregates with a cross-tenant reference — never routed through
  `bin/qa_domain_novelty` either, for the identical reason).

## What this domain builds

One aggregate (`Lease`), one Integer clock value object
(`LeaseInstant`, `qa/bluebook`'s own `Instant` redeclared per this
corpus's "never shared by name across a domain boundary" habit), four
commands, and one query — deliberately not combined with the reference-
hop stress `referral_chain` already owns or the entity nesting
`nested_pieces` already owns, so a divergence this domain finds is never
ambiguous about which construct it belongs to:

- `Register` — creates a lease slot, no clock at all.
- `Acquire` — free→held, or held→held when the CALLER'S OWN passed `now`
  already clears the previously recorded `expires_at` (`Target.Claim`'s
  exact shape). Two `given`s read the same stored field against two
  different passed arguments for two different reasons (the record's
  own past, and the record's own future).
- `Renew` — held→held, gated the mirror-image way: only while the
  stored expiry has not yet met the passed `now`, and only to a
  strictly later passed expiry — the one command reading `expires_at`
  for a comparison AND overwriting it in the same dispatch.
- `Release` — held→free, no clock argument at all (a holder can hand a
  lease back whenever).
- `Reap` — held→free, role-gated ("Operator", distinct from every other
  command's "Client") and clock-gated the opposite way from `Acquire`:
  refuses unless the passed `now` has already reached the stored
  `expires_at`.
- `Expired` (query) — takes `now` as its own declared attribute,
  compared via `lte` against the stored `expires_at`
  (`Patch.OpenedSince`'s `gte` shape, mirrored and inverted), paired
  with a second, unrelated `where` so it never lands on `tenant_ledger`'s
  own already-logged codegen finding (a query declaring only
  `authorize`/`tenant:` and no other `where` skips for the wrong
  reason) — this query declares no `authorize` at all.

## Ruby-only fuzz status

`bin/fuzz qa/stress_domains/lease_clock --seeds 40 --steps 30` — CLEAN,
40 of 40 seeds, no property violation, no interpreter exception.
`bin/model_check qa/stress_domains/lease_clock` — 0 errors, 0 warnings,
clean (no terminal state in this domain's own two-state lifecycle, so no
`ALLOWED_FINDINGS` entry needed, matching `waybill`'s/`tenant_ledger`'s
own precedent of leaving that allowlist untouched for a domain outside
`MODEL_CHECK_CORPUS`).

## First-run differential result (Ruby vs. compiled Rust) — two findings

`bin/project_rust qa/stress_domains/lease_clock`, then `cd rust && cargo
build --release --no-default-features --features lease_clock`, then
`SEEDS=10` `bin/rust_conformance_fuzz qa/stress_domains/lease_clock
native` — diverges at seed 3. A hand-written scan over 60 generated
seeds (30 steps each), grouping by each seed's FIRST divergent refusal
(everything after the first divergence in a seed is a cascade — once one
engine accepts what the other refused, the two replays are no longer
running the same effective sequence, so later indices diverge for
reasons unrelated to this domain) found exactly **two** distinct root
causes, 49 of 60 seeds carrying one or the other:

### 1. Big-integer clock value — f64 precision loss in Rust's JSON parser (already-documented class, new site)

Minimal repro (`bin/rust_conformance qa/stress_domains/lease_clock
<script> native`):

```json
{"steps": [
  {"verb":"LeaseClock::Lease.Register","args":{"key":{"value":"a"}}},
  {"verb":"LeaseClock::Lease.Acquire","args":{"holder":{"value":"h"},"now":1267650600228229401496703205376,"expiry":{"value":2},"key":{"value":"a"}}}
]}
```

Both engines refuse `TypeMismatch` — but with different wording. Ruby's
arbitrary-precision integers report the exact overflow value
(`"LeaseInstant.value must fit in a 64-bit integer, got
1267650600228229401496703205376"`); Rust's `f64`-backed JSON parser has
already lost precision by the time it reports the same refusal
(`"LeaseInstant.value expects Integer, got
1267650600228229400000000000000"`). This is the exact,
already-documented `Json::Num`/f64 precision-loss class
`spec/support/rust_conformance_helpers.rb` names in its own header (the
same `1.27e30`-shaped example) and `tenant_ledger`'s own NOTES.md already
logged (its finding #2, on `LedgerAmountCents`/`TransferAmountCents`) —
not new as a class, just the first time it fires on an Integer value
object used explicitly as a CLOCK reading rather than a money amount,
and the first time it fires on FOUR distinct sites in one domain
(`Acquire.now`/`.expiry`, `Renew.now`/`.expiry`, `Reap.now`, and
`Expired.now` as a QUERY argument — the query-argument site is itself
new, since no prior stress domain's query took an Integer argument at
all). 34 of the 60 scanned seeds carry only this signature.

### 2. `null` for a query's own required Integer argument — Ruby answers silently, Rust refuses (new)

Minimal repro:

```json
{"steps": [
  {"verb":"LeaseClock::Lease.Register","args":{"key":{"value":"a"}}},
  {"verb":"LeaseClock::Lease.Acquire","args":{"holder":{"value":"h"},"now":{"value":1},"expiry":{"value":2},"key":{"value":"a"}}},
  {"query":"LeaseClock::Lease.Expired","args":{"now":null}}
]}
```

Ruby: no refusal at all — `Expired` runs and answers `rows: []`, even
though an unexpired, currently-`held` lease exists (verified directly
against `Hecks::Fuzzing::Replay`'s own `:queries` result). Rust:
`TypeMismatch`, `"LeaseInstant.value expects Integer, got nil"`. This is
a genuine KIND divergence (a refusal on one side, a plausible-looking
but silently wrong answer on the other), not just wording — the
by-kind comparison (referral_chain's own NOTES.md calls this "C8.2")
sees it immediately. Root cause, read directly off the behavior: a
query's own declared value-object argument goes through
`QueryInterpreter#normalize_args`/`Ports::Query::InMemory`'s own arg
handling, which apparently only builds/invariant-checks a VALUE-OBJECT
argument when the caller's JSON carries a non-null value for it — a
`null` is treated as "no constraint," so `Comparison.ordered?` (`held.
is_a?(Numeric) && want.is_a?(Numeric)`) sees a `nil` `want` and quietly
returns `false` for every row, rather than the argument ever being typed
or invariant-checked at all. `rust/project/queries.rb`'s own generated
`query_arg_checks` (see that file's own C3.7 comment: "a VALUE-OBJECT
argument IS built for real ... dropped: the typed value is only a gate
here") builds the value object whenever the JSON key is PRESENT — even
mapped to `null` — and its own `from_json` refuses a null there outright.
This reads as the query-side analog of `referral_chain`'s own finding #3
(a `null` reference is tolerated by Ruby's write-side `resolve_
references`, `next if held.nil?`, while Rust's generated `from_json`
requires a JSON string) — same "Ruby tolerates an absent-shaped
required argument, Rust does not" theme, one construct family over (a
query's own declared attribute rather than a command's reference
field), and the first time it has been exercised against Rust at all:
no existing Rust-fuzzed domain declares a query with a required,
non-optional value-object-typed argument compared via `where` (the only
corpus precedent, `qa/bluebook`'s own `Patch.OpenedSince`/`Target.
Claim`, is Memory-only, never generated). 15 of the 60 scanned seeds
carry only this signature.

Neither finding is fixed here, on purpose — same restraint `waybill`/
`nested_pieces`/`referral_chain`/`tenant_ledger` each held to: this
domain was authored from an isolated worktree, and the
`Bug.log`/`triage`/fix lifecycle belongs to the session holding the
ledger. Both have a minimal repro script above; neither is a defect in
this domain's own bluebook.

## Not done here, on purpose

- `bin/qa_domain_novelty`'s default mode (reading `Target.path` off the
  live ledger via `bin/run qa/bluebook ask target.all`) was not run —
  this PR only ran the `--against`-with-explicit-paths mode, to avoid
  booting the live ledger from an isolated worktree at all. Identifying
  this domain as a `Target` (`bin/run qa/bluebook identify …`) is the
  orchestrator's own ledger write, not this PR's.
- The two findings above are reported here, not logged as a `Bug` in
  `qa/bluebook` — logging requires the live ledger and a fresh
  `BUG#<n>`, both explicitly out of scope for an isolated-worktree
  stress-domain PR (the same restraint every prior stress domain in
  this directory held to).
- `spec/rust_conformance_fuzz_spec.rb`'s own `DOMAINS` list is PR-2's
  own file to touch (ANGLE-3 in the QA ledger's own detection plan), not
  touched here.
