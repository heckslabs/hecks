# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Dates are when a change landed on `main`, not when this file was written.
Entries below are grouped by theme, not itemized commit-by-commit; see
`git log` for the full history.

## [Unreleased]

## [1.2.0] - 2026-09-09

**`rust/host` closes its silent-wrongness gaps against a real
persistence backend.** It now refuses loudly at boot when a domain
binds an aggregate to a persistence adapter it has no backend for
(previously it dispatched through its own flat Postgres path
regardless of what the domain declared, with lineage/era boot gates
skipping silently since Heki is never lineage-capable). Its
cross-domain delivery loop no longer drops sibling reactions the
instant one delivery exhausts its retries. `PostgresEra`'s advisory
lock (ADR 0036) now covers its whole cross-process dispatch order
instead of only `append`/`atomic_put`, and its lock-key domain default
no longer risks colliding with an unrelated domain when constructed
without an explicit `domain:`.

**`bin/run` no longer crashes on any domain that declares a `port`.**
`CliProjector#port_spec` called a method (`receiver_options`) defined
nowhere in the codebase — `examples/pizzas`' `PaymentGateway` port
included, so `bin/run examples/pizzas` failed with `NoMethodError`
before printing even a help listing. No corpus domain's `.bluebook`
exercised a port, so nothing caught it until now.

**Rust parity fixes from the ongoing Ruby/Rust survey.** Closed-set
(`one_of`) `from_json` admission now matches Ruby's check ordering
instead of requiring the wrapped-string shape before admission is
checked; `corrects` now ports `reverses: true` (increment/decrement)
correctly; policies and process managers now merge across chapters the
same way Ruby does. ADR 0037's remaining "honest addendum" divergences
were re-verified live (not just re-read) — one closed outright, the
rest confirmed already fixed by the generated-dispatch reordering that
shipped for Findings 3-5.

**Reliability and hygiene:** Postgres adapter self-heals a missing
column or a killed connection on boot instead of failing over the
whole domain; two specs that were silently passing without exercising
the behavior they claimed to (`read_model_interpreter_spec`,
`parser_parity_spec`) now actually test it; a new Ubiquitous Language
glossary projector; value-object *lists* now hydrate correctly (ADR
0047 previously only covered single value-object attributes);
`read_model`'s `on:` now names which many-side a nested
`where`/`order_by`/`limit`/`offset` targets; `rspec_rust_io` splits
into 3 parallel CI jobs.

## [1.1.0] - 2026-09-09

**Transactional outbox for domain events and external effects (ADR
0053).** Every reaction a dispatch owes — a policy or process manager's
own trigger, plus any outbound port operation — is now recorded as one
row per (event, consumer) in the SAME adapter transaction as the
aggregate's own save, not announced in-process and hoped for. The
dispatcher drains it inline right after (`pending` → `claimed` →
`delivered`/`failed`); anything still `pending` at the next boot is
redriven automatically, and anything `claimed` is surfaced for a human
rather than silently retried. New adapter contract
(`transaction`/`outbox_enqueue`/`claim`/`settle`/`rows`) on Memory,
Sqlite, Postgres and PostgresEra; Sqlite's own plain `save` is atomic
now as a side effect of making its transactions re-entrant. Adapters
with no outbox implementation (Heki, LocalStorage, D1 today) get a
boot-time warning rather than a silent gap. See ADR 0053 for the full
design and `runtime.outbox.rows`/`redrive!`/`log` for inspecting it
live.

**LocalStorage: a `persisted_by` adapter for browser-hosted domains.**
Mechanically identical to Memory — Ruby has no way to reach a real
browser's `window.localStorage`, so an honest Ruby-side implementation
can only be an in-process stand-in — but it declares real intent:
`persisted_by "LocalStorage"` says a domain expects durable,
single-device, browser-side storage the moment it actually runs where
it's meant to, the same distinction Heki already draws against Memory.
The real browser half lives in `rust/web`'s existing `dispatch(json)`
contract (ADR 0015): an optional `"seed"` (the same `"instances"` shape
`dispatch` answers with) plus `"steps"` lets a host rehydrate from a
prior snapshot and replay only new commands, instead of the whole
history every call — a page bound to this adapter holds that snapshot
in `window.localStorage` itself. `query:` falls back to
`Ports::Query::InMemory` (same trade Heki and Memory both take);
`lineage_capable?` is `false` (no era story — a shape change needs a
hand migration, same as Heki); `tenant_capable?` is trivially `true` (a
browser tab is exactly one origin, one user).

**The Bluebook semantics document's remaining open clauses are all
settled** — the last stretch of a long-running effort to make every
place Ruby and the Rust kernel could quietly disagree either provably
agree or name the gap explicitly (`docs/semantics/bluebook-semantics.md`;
the corpus-owned fixtures under `spec/corpus/semantics/` pin each one
on both runtimes where both apply). The ones most likely to actually
change behavior in an existing domain:

- **Integer is a signed 64-bit integer everywhere (C3.3).** A bare
  argument past ±2^63−1 is now a clean `TypeMismatch` at the boundary,
  and an expression sum or a `then_set` `increment`/`decrement`/
  `multiply` whose result leaves that range is an evaluation `Fault` —
  both runtimes now refuse where Ruby's own arbitrary-precision
  `Integer` used to silently promote to Bignum and keep going. If a
  domain relied on genuinely unbounded integer arithmetic anywhere
  reachable from user input, this is worth checking against.
- **Float is finite (C3.4).** `NaN` and the infinities are refused at
  bare-argument boundaries too, and a non-finite sum is the same
  `Fault` as C3.3's integer overflow.
- **A command's effects are one update set over the PRE-dispatch state
  (C4.2), and appended-entity identities mint highest-plus-one, never
  size-plus-one (C4.5).** Every mutation source — argument, literal, or
  `state(:field)` — reads the record as it was before the command, not
  as an earlier mutation in the same command left it; declaration
  order carries no meaning, and writing the same field twice in one
  command now refuses at build instead of silently last-wins.
- **The Rust kernel now enforces aggregate and entity invariants
  (C6.2).** It previously had no invariant step at all — a deployed
  Rust domain would accept states Ruby refuses. Value-object
  validation itself only ever runs on construction from real input,
  never on a trusted reload from storage (C6.3).
- **A delegated leg's events are emitted with the parent's own commit,
  never before it (C7.2).** Ruby used to emit a delegated entity's
  event the moment that leg succeeded, before the parent's own
  `ensures`/invariants/save — so a parent that went on to refuse had
  already left the leg's event on the log and in the adapter. Rust was
  already correct; Ruby now matches.
- **An evaluation fault is its own outcome, never a refusal (C8.3), and
  every declared command argument is type-checked at the boundary
  regardless of shape (C3.8).** A bare primitive argument of the wrong
  type — not just a malformed value object — is now a clean
  `TypeMismatch` refusal instead of a chance to reach rule evaluation
  and fault there instead.
- **A saga leg is selected by (event, current state), not event name
  alone (C10.3), and reactions for one dispatch's whole batch of
  announced events run after every event in that batch commits, per
  event, policies then sagas (C10.2).** Two legs answering the same
  event from different `from:` states are refused as ambiguous at
  build now, rather than one being permanently unreachable.
- **A `corrects` target is judged against the aggregate's own durable
  event history, not in-memory state (C9.2);** an `ensures` reads the
  settled (post-mutation) state when a name is both an argument and a
  field, the mirror image of how a `given` already reads the
  pre-mutation state (C2.3); and the lifecycle field moves only by a
  declared transition — a bare `sets` on it, or two transitions for
  one command with overlapping `from:` states, now refuses at build
  (C5.3).

All of the above apply to existing domains without any DSL change —
they tighten what was previously either silently wrong on one runtime
or genuinely undefined, not new syntax to opt into.

**Deploy tooling: `bin/project_wasm` now honors the `HECKS_PARSER=rust
HECKS_CODEGEN=rust` opt-in `bin/project_rust` already did.** Previously
it unconditionally shelled out to the Ruby generator regardless of that
env pair, so the `.wasm` a deploy Makefile's `build-<LogicalId>` target
ships to Lambda went through Ruby even when the rest of a toolchain was
built Ruby-free. Opted in, it now delegates to `hecks-build --wasm`
instead of running its own regenerate-then-`cargo build` sequence.

**A `hecks-codegen` crash on a delegating command with a single
mutation is fixed** — found closing an unrelated corpus-coverage gap
(`examples/roster` had never actually been proven byte-identical
between the two Rust generators despite being in CI's own trusted
drift-check corpus). Only reachable through the opt-in all-Rust
pipeline (`HECKS_PARSER=rust HECKS_CODEGEN=rust`); the default Ruby
generator was never affected.

**`IsolatedBoot` tolerates a transient file vanishing mid-copy** — a
real race under the pre-push hook's own parallel test runner, where
another worker's atomic Heki write can drop a `.tmp.<pid>` file between
the directory glob and the copy. Development/CI-only; never affects a
deployed domain.

**A test fixture that embedded a real-looking production database
endpoint and password (for a URI-reserved-character parsing test) now
uses a synthetic value that preserves the same reserved characters.**
No evidence it was ever a live credential; fixed as hygiene regardless.

**Single-element value objects strictly answer `.value`.** A value object
with exactly one declared attribute is a name for a scalar, and the
language now treats that as a rule rather than a convention:

- New bare shorthand: `value_object "Price", Integer` — no block, a type
  in second position — declares exactly one attribute named `value` of
  that type; pure sugar for the block form's single `attribute :value,
  Type` line (byte-identical IR). Type AND block together refuse
  (`Malformed`); bare `value_object "Name"` with neither keeps its
  historical empty-attribute behavior. Grammar rows, the Rust parser
  (`hecks-parse`, byte-exact parity), and reference docs all carry the
  new spelling.
- Runtime alias: every single-attribute value object answers `.value`
  (and `[:value]`/`key?(:value)`/`with(:value, ...)`), aliasing its real
  sole field whatever it is named — `Money{amount}` and `Label{value}`
  read identically. Multi-attribute value objects keep refusing
  `.value`. Serialization is deliberately NOT aliased: `to_h`/`to_json`
  keep the real field name.
- The scalar-unwrap rule is count-gated, not name-gated, everywhere both
  engines read it: `Resolver#unwrap_scalar`, the generated Rust
  `Fielded::as_scalar` (rust/project + rust/codegen, in lockstep), the
  kernel's own `Json::as_scalar`, SQL member-picking
  (`SqlQueryBuilder#query_expression`), and Memory ordering
  (`InMemoryOrdering#sortable_path`) — a bare-field predicate or query
  over `EmailAddress{address}` now means its one field, exactly as it
  always did for a field literally named `value`.
- Call-site collapsing (already count-gated in
  `Coercion#fields_for`) is now documented and pinned as part of the
  language: `price: 10` and `price: { amount: 10 }` build the identical
  single-attribute value object; the explicit spelling keeps working,
  and multi-field shapes still require their fields spelled out.

**The translation audit's preview now reads through the SAME
layered-or-full SQL selection a real mint materializes with.**
`translated_latest` (`bin/translation_audit`'s own preview, and the
real mint-time gate in `coverage_check.rb#audit!`) used to call
`chain_sql` unconditionally; `compile_head!`, at actual mint time,
picks the LAYERED build instead whenever era >= 3 and a prior matview
exists — most eras of any domain that has minted more than a couple of
times. The two were asserted equivalent by spec, but only tested for
an ordinary (non-rekey) edge; a rekey's own `id_column` CASE went
through the layered path at real mint time and through `chain_sql`
alone at every preview, two independently-maintained implementations
with no shared test ever exercising both for the SAME rekey. Pulled
into one `head_body_sql` picker both call, with a defensive
`edges.size != era - 1` guard on the layered path (a caller handed a
shorter edge chain against the same target era — the audit's own
"before" reading always is — used to index past its own array bounds
instead of falling back cleanly). A rekey reaching era 3+ now audits
against the literal SQL a real mint will run, not a second guess at it.

**`.set?`/`.unset?`, a deliberately narrower sibling of `.present?`/
`.blank?`.** `!receiver.nil?`, full stop — an assigned-but-empty
`String`/`Array` is `.set?`, unlike `.present?`'s own Rails-standard
emptiness reading of the identical value. For an optional field whose
only legitimate unset state IS nil, that conflation was a real trap;
these ask the narrower question by name instead. Ported to the Rust
kernel (`Expr::Assignment`, `expression_operators::presence`) alongside
the Ruby resolver; `rust/host`'s JSON interpreter parses it structurally
but does not yet evaluate it, the same boundary `.present?`/`.blank?`
themselves already sit behind there.

**`GivenNotMet#detail`.** A refused `given` whose top-level shape is a
bare comparison now carries its own resolved operands — "left: X,
right: Y" — as `#detail`, off `#message` (every corpus spec asserting
an exact refusal string keeps passing unchanged). Rides on Ruby's own
`#detailed_message` (3.2+), so it shows up in an irb/console
unhandled-exception banner without any caller code reading it on
purpose.

## [1.0.2] - 2026-08-28

**Gem page cleanup, now that the gem is actually published.** `1.0.0`
shipped before `gem install hecks` was live on RubyGems, so the README's
Quickstart still said "There is no published gem" and had no Install
section — the first thing a visitor reads contradicted reality. Fixed:
an `## Install` section now sits right after the intro, and Quickstart
points at `git clone` for the examples/docs rather than implying it's
the only way in. Gemspec also gained `changelog_uri` and
`documentation_uri` metadata, which render as links on the RubyGems page;
`homepage`/`source_code_uri` were already correct (`heckslabs/hecks`,
not the `chrisyoung/hecks` fork/redirect). Metadata is baked into the
published gem version, so this needed its own release rather than
riding along on `1.0.1`.

## [1.0.1] - 2026-08-28

**Cross-tenant boot-isolation gap closed.** `refuse_unless_tenant_capable!`
existed and was directly tested (ADR 0025's gate), but nothing in the boot
path actually called it — a second tenant booting the same directory on a
tenant-incapable adapter went unrefused. Wired into
`ProjectRegister#register` rather than `run_boot_gates!`: boot gates run
per-boot and have no way to see a prior boot, while `ProjectRegister` is the
shared route table where two tenant boots of one directory actually
converge, keyed on `[directory, bluebook.name]`. The first registration of a
directory is never refused, so a plain single-tenant deployment boots
unchanged; a second, incompatible tenant is refused before its routes are
added to the table, so a leaking tenant is never reachable through
`Router#resolve`. `1.0.0` shipped with this gate unwired; anyone who pinned
that version should move to `1.0.1`. See `docs/1.0-readiness.md`'s "Known
gaps at 1.0" section for what's still open (read-model cross-engine
agreement, ADR 0037 findings 3-5).

## [1.0.0] - 2026-08-28

**ADR 0025 lands: the DSL redesign this whole cycle was blocked on.** All 15
slices (S0a/S0b, S1–S13) are done — see `docs/dsl-work-slices.md` for the
full per-slice record. This is the breaking cleanup the 1.0 promise is being
made *about*, not incidental to it:

- `has_many` / `has_one` / `belongs_to` deleted; `reference_to` is the one
  spelling for a reference.
- `identified_by`'s three forms collapsed to one.
- Reference traversal gets its own `/` hop operator, split from `.`'s
  field-walk.
- The attribute type position loses the quoted-string and default-to-`String`
  forms — a bare constant is the only spelling; `one_of:` replaces the
  closed-set wrapper block for the single-field case.
- Events are first-class: `emits`/policy `on`/saga `transition`/`starts_on`/
  `ends_on` all take a bare constant (`Order::Placed`), not a quoted string.
  The full corpus (`examples/`, `lib/hecks/framework/bluebook/`, the
  self-hosted language's own grammar) is migrated — 136 sites moved off the
  quoted spelling; the 2 remaining (`PortOperation#emits` in pizzas'
  `PaymentGateway` port) are a deliberately different, text-kind grammar
  context, not an oversight. The old quoted spelling is still accepted
  everywhere, not refused — refusing it is a separate, undecided design call.
- `projects` gives an aggregate a synchronously-seeded local copy of a
  cross-aggregate field, replacing direct stored-reference dereferencing in
  `given`/`ensures`/`invariant` — an explicit, documented eventual-consistency
  tradeoff (`RebuildSweep` covers out-of-band drift).
- A real corpus use or a named, reasoned exemption for every documented DSL
  word (`spec/word_coverage_spec.rb`), so the reference docs can't silently
  drift from what the language actually does.

`docs/1.0-readiness.md`'s gate is satisfied: ADR 0025 landed with the corpus
migrated and docs regenerated, the property fuzzer's real-adapter mode
covers Postgres/Sqlite, the 8 previously-open GitHub issues and the full
issue-tracker reconciliation (`hecks-hecksagain` epic, `qa-legacy`, misc) are
closed at 0 open, and the M1–M19/L1–L24/Rust-parity divergence list is
re-verified (53 of 55 fixed or no longer applicable; the 2 remaining carry
an honest caveat rather than a false "fixed" — see
`docs/audits/2026-08-28-m1-m19-l1-l24-rust-parity-reverify.md`).

**Update, 2026-08-28, same day:** the Rust runtime projection gap named
below as a known, out-of-scope-for-1.0 limitation was closed the same day,
in the same release — PR #433 seeds `projects` fields at dispatch time in
Rust (`ProjectedFieldSpec`/`seeded_projections`/`SetProjectedField`,
`rust/src/kernel/reference_lookup.rs`), closing every one of the 15
`rust_conformance_spec` failures the gap below describes. `rust_conformance_
spec` is 23/23, zero failures, as of this release.

**Known, out-of-scope-for-1.0 gaps**, tracked separately rather than
silently shipped: a real dangling-reference data-integrity gap found by the
generated-sequence fuzz bridge (ADR 0037 Finding 5); S18 (migrating `raise
Malformed` call sites into the meta-domain — scoped, not started, ADR 0026).

Everything below this line is unchanged content from `[Unreleased]`, carried
forward as this release's own history.

### Fixed

- **The Storehouse MCP bus dispatched role-gated commands unbound.**
  `dispatch` now refuses a command that declares a `role` when no caller
  (`role:`/`actor_id:`) is bound, rather than silently running it
  unchecked — the fail-open half of ADR 0025's `role` work that the
  Governance RBAC lookup itself didn't touch (that step only upgrades
  what a *bound* role is checked against). `domain:`/`under:` on every
  Storehouse tool are now confined to `Hecks::Storehouse::BOOT_ROOT`
  (the project directory by default, `HECKS_STOREHOUSE_ROOT` to widen
  it) — `Hecks.boot` loads real Ruby, and an unconfined caller-supplied
  path was an unmarked way out of the "narrower, checked surface" this
  bus exists to provide. `bin/hecks_mcp_door` now states its stdio-only,
  unauthenticated-identity transport assumption in its own header; the
  README's authorization claim for this bus is corrected to match.
  (2026-08-27)
- **Entity dispatch had no argument gate at all (H1).** Every aggregate
  command and port operation refuses unknown/absent arguments;
  `EntityInterpreter` (an aggregate's own owned pieces — `Account
  .LedgerEntry.Reverse`) silently didn't, on a comment claiming it
  "inherited" a check nothing on its path ever ran. A bogus argument was
  silently accepted; an omitted declared one silently nil'd the field it
  should have set. Fixed, with a correct addressing rule for multi-hop
  entity chains and a pinning spec. (2026-08-27)
- **The property fuzzer only ever ran against the Memory adapter.**
  `bin/fuzz --adapter sqlite|postgres` now runs the full property battery
  against real Sqlite and real Postgres, not just in-memory. Along the
  way, fixed a real bug this surfaced: any Postgres-bound domain with a
  reference-hop query field (`owner/field`) failed to boot at all
  (`PG::UndefinedColumn` in `SchemaBuilder#index_field!`) — previously
  unreachable because nothing had run such a domain against real Postgres
  before. (2026-08-27, PRD 02)
- **`Gemfile.lock` wasn't committed.** The `json` gem was already pinned
  exactly in the `Gemfile`, but every other dependency was free to float
  between CI runs with no diff to review. Committed a lockfile generated
  from a clean `bundle install`. (2026-08-27)
- Era-migration/rekey data-loss findings (H3–H5): deleting an
  era-migrated record no longer resurrects the ancestor era's row in the
  head view; rekey SQL is now folded into the human-approval digest, so
  editing an approved rekey's mapping invalidates the approval; a
  dotted-member `compute` no longer exempts its whole parent attribute
  from the Layer-2 cross-execution equivalence gate. Verified live
  against real Postgres.
- Query engine correctness (H6–H9): `limit`/`offset` ordering across the
  in-memory and reference/entity query engines now matches SQL
  (offset-then-limit, not limit-then-offset); dotted field paths go
  through `FieldPath.dig` everywhere instead of raw hash access; `one_of`
  closed sets are covered by `seal_defaults` (a closed-set attribute with
  a `default:` no longer refuses its own default on create); the
  meta-validator's cache key now incorporates read-model filters, so an
  edited `where`/`order_by`/`limit` can't serve a stale cached filter.
- Routing/deploy correctness (H12–H14): a record id containing `.`
  (e.g. an email-typed identity) now routes correctly instead of 404ing;
  `make deploy` no longer reports failure for a successful Shared-mode
  deploy; `scaffold-translation`/`translation-audit` now refuse by
  default rather than silently scaffolding/auditing the local dev
  database when they'd otherwise miss the intended tunnel.
- Session security (H11): the Rust web layer's session/OAuth-state HMAC
  now refuses to boot on an empty/unset `SESSION_SECRET` instead of
  keying on a publicly-known empty string.
- Systemic query/type-safety root causes (S1–S3): typed query values no
  longer collapse to `.to_s` on the wire; a stored `false` no longer
  reads back as `nil`; identity-value escaping paths reviewed.
- The nested-reaction-dispatch race (`@reaction_depth`) is fixed —
  `Thread.current`-backed, not a shared ivar, safe under a threaded Puma
  deployment.
- 10 real Ruby/Rust parity bugs across the parser, codegen, and kernel,
  including a missing `formerly_known_as` field in the Rust parser that
  broke every `parser_parity`/`codegen_parity`/`rust_conformance`
  fixture that didn't declare it.
- `AppendOnly#record_event`: domain events were never actually persisted.
- A lost-update gap in state-dependent command dispatch.

### Added

- `docs/1.0-readiness.md` — a single, explicit statement of what a `1.0`
  tag will mean, why it isn't tagged yet (blocked on
  [ADR 0025](docs/decisions/0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md),
  a real breaking DSL redesign), and everything else that has to be true
  first.
- `CONTRIBUTING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/`,
  `.github/PULL_REQUEST_TEMPLATE.md`.
- `chess` as a new example domain.
- The universal MCP dispatch door (`dispatch`/`query`/`state`/`catalog`/
  `describe`/`validate`/`history`/`follow`/`behaviors`), renamed
  `Storehouse`.
- `bin/follow` — a live tail of a domain's append-only journal.
- `corrects` — a retroactive-correction DSL command word.
- Generated Mermaid diagrams (`<Aggregate>_surface.mmd`,
  `<ProcessManager>_saga.mmd`, `frameworks.mmd`) and a README "Diagrams"
  section held to them.
- ADR 0033/0034/0035: eras/lineage extracted behind a registered boot
  gate as a loadable Ruby plugin, with optional Rust lineage.

### Changed

- README rewritten for adoption; the Quickstart-blocking bug it exposed,
  and a license gap, both fixed.
- Removed client-specific deploy artifacts (`embryonaut`,
  `lifeadelics*`) that had been tracked alongside the public example
  domains.

### Docs

- Reconciled `docs/future-features.md`'s "Bug audits" section against
  current `main` — every `H`-numbered audit finding is now marked with
  its real, live-verified status instead of a stale "still open as of
  2026-08-11" blanket claim. See that section for exactly what was and
  wasn't re-verified this pass.
- Fixed a tracking-doc row that wrongly claimed the fuzzer-adapter gap
  was fixed by an unrelated commit (`docs/audits/2026-08-26-issue-tracker-reconciliation-plan.md`) —
  found independently, alongside H1 above, while reconciling docs
  against code in both directions.

[Unreleased]: https://github.com/heckslabs/hecks/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heckslabs/hecks/compare/v0.3.0...v1.0.0
