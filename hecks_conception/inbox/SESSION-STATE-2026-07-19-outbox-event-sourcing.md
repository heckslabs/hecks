# SESSION STATE — 2026-07-19 : outbox arc CLOSED + framework collaborator step zero

`main` is clean, green, and PUSHED through `1e49c0ef4`. Full suite 125/125 test
binaries, hecksagon parity 400/400, behaviors 152/152, zero warnings.

The three planned slices are DONE. The arc also flushed out three bugs that were
not on the plan, one of which had disabled a gate.

## Shipped this session

- `cf274e2d7` **slice 1** — end-to-end proof the `event_sourced` directive
  writes the Log. Boots a real corpus with the real `outbound_event.hecksagon`,
  dispatches Record -> Claim, asserts the deltas land as `EventSourcing::Event`
  records. Carries a NEGATIVE CONTROL (a sibling aggregate without the directive
  writes nothing) so a stray `HECKS_EVENT_SOURCING=1` cannot make it pass for the
  wrong reason. Mutation-checked at the runtime gate, not only the parser.
- `bbf680145` **loc-ratchet root cure** — see below, this one matters.
- `96d1aa66b` **query shape** — a query result is ALWAYS a list. It used to
  render a bare OBJECT for one record and an ARRAY otherwise, so the result TYPE
  depended on the DATA. Ruby was already correct ; this was Rust-only drift.
- `0bd076d20` **slice 2** — the pending predicate moves into the bluebook. A
  declared `AllPending` query replaces `status == "pending"` re-implemented at
  three Rust call sites.
- `50b3b8db7` **slice 3** — the outbox grafts only for a domain's OWN effect
  port.

## Slice 3 was NOT what the old plan said — read this before trusting the plan

`PLAN-outbox-as-projection-not-aggregate.md` says slice 3 is "delete the
injection". **That instruction is stale.** It was written under the PROJECTION
model (model B), where the outbox was not an aggregate at all. Model A — locked
since — makes the outbox a normal `event_sourced` aggregate, so bundling it as
runtime stdlib is coherent (the `CascadeRun` precedent), and deleting the graft
would strand standalone-served effect domains.

The real defect was narrower : `ensure_outbox_substrate` asked "does ANY attached
hecksagon carry an effect binding?" while `serve_directory` deliberately loads
EVERY hecksagon under the served tree AND the repo. So one `charged_by` anywhere
grafted `OutboundEvent` onto every served domain — the ToolShed symptom. Proven
before the fix : a domain whose only aggregate is `Loan`, booted with a FOREIGN
Shop binding, came back `["Loan", "OutboundEvent"]`. Fix scopes the predicate to
bindings targeting THIS domain, which also satisfies the standalone-serve
constraint by construction — no runtime-owned merge, no UI filter (the shape
that was built once and reverted).

## The loc-ratchet was disabled and nobody knew

Worth reading `bbf680145` in full. Two bugs whose effects cancelled :
- `bin/loc-ratchet` read its fixtures from a path missing the `bluebook/`
  segment, so it silently fell back to hard-coded concerns.
- The DECLARED fixture said `direction: "grow", baseline: "31460"` under a
  comment describing a shrink gate that "ratchets down from 31460". `grow` never
  fails. The declaration was NO GATE AT ALL.

The fallback was STRICTER than the declaration it stood in for, so fixing only
the path would have switched the kernel's main pressure gate OFF and printed a
green check doing it (`base=31460 head=38170 delta=+6710 OK`). The declared
fixtures had drifted to the opposite of their own documentation precisely BECAUSE
nothing was reading them. **A gate nobody reads doesn't fail, it rots.**

Root cure : `dump-fixtures --domain <Name> --corpus <root>` — the script names a
DOMAIN, the corpus resolves the file. Verified by MOVING the fixtures to another
directory and confirming the gate still reads them.

## Method notes

- **The ratchet LAGS one commit.** The pre-commit hook reports the PREVIOUS
  delta. I misread that as "delta=0", amended out a `[loc-ratchet-override]` as
  unnecessary, and wrote a false claim into a commit message. True delta was +20.
  Measure with `bin/loc-ratchet --base origin/main --verbose` against the amended
  tree ; never trust the hook's number for the commit you are writing.
- **Mutation-check both directions.** Stripping the `event_sourced` directive
  failed only the PARSE guard and said nothing about the runtime ; forcing
  `aggregate_is_event_sourced` to false was the check that meant something. A
  test that passes first try deserves suspicion.
- Antibody exempts the Rust runtime by category but NOT `bin/` scripts or
  `ruby/`. Let it block, report verbatim, let Chris decide per file.
- Parity : `cargo build --release -p storehouse-cli --bin storehouse` (from
  `rust/`), then `ruby -Iruby parity/hecksagon_parity_test.rb`.

## Framework collaborator — STEP ZERO SHIPPED (`1e49c0ef4`)

The card's two killer risks are resolved. `Runtime` now carries
`framework: Option<Box<Runtime>>` — a lazily-booted second runtime on
crate-owned substrate that the kernel dispatches into, instead of requiring the
substrate to be merged into the USER's domain.

- **Borrow shape works.** `record_event_append` runs inside `&mut self` and
  calls the collaborator cleanly (`heki_path()` returns owned, so the store-dir
  borrow ends before the per-delta dispatch re-borrows). First compile, zero
  warnings.
- **Behaviors stay green** (152/152) — the collaborator boots LAZILY, so the
  corpus never pays for it.
- **The closed bug** : a single-bluebook boot declaring `event_sourced` used to
  write NOTHING, silently. That is now a passing test.
- **Backwards compatible by accident worth keeping** : the collaborator inherits
  `data_dir`, so existing `rt.all_qualified(Some("EventSourcing"), "Event")`
  readers still see the Log. Verified by MUTATION, not assumed.

**GOVERNANCE DONE** (`8045e5b2e`) — a denied dispatch always leaves an audit
row. It had been `let _ = self.dispatch_impl(...)`, so on a runtime without the
Governance conception the row was discarded silently. `authorize_pdp_test`
boots exactly such a runtime and had been asserting denials that recorded
nothing. The denial always stood — never an authz hole — but the RECORD of who
was refused what was contingent on corpus layout.

**IT IS THREE SUBSTRATES, NOT FOUR.** The card's original claim was corrected :
CascadeRun's guard selects between TWO WORKING PATHS (persistent outbox vs the
in-memory pump), not between working and losing data. `mod.rs:1204` says so
outright. It should NOT move ; doing so would change dispatch semantics for
every runtime for no correctness gain.

Also REJECTED : a suspected cross-domain cascade-drain bug (every served runtime
shares `<dir>/data`, CascadeRun has no domain discriminator). Probed with two
runtimes on one data dir — not reproduced, because `dispatch` pumps to
quiescence so runs complete before a sibling sees them. Don't re-derive it.

**NEXT : OutboundEvent, and it is a real refactor — not a repeat.** See the card
for the scoping. Short version : the lifecycle commands are dispatched by SHORT
name from `run_host` and the pump/drain ; the consumers straddle both runtimes
(Claim/MarkDelivered to the collaborator, verdicts to the parent) ; `run_host`
is a separate program booting its own runtime off disk. It is also the LOWEST
urgency of the three, because the graft already patches its coupling — nothing
is silently lost today. The shrink (seven guards, the graft, its predicate,
`outbox_graft_scope_test`, and eventually `substrate_parity_test` with its
duplicate bluebooks) lands when it moves.

## The card, for full context

`inbox/CARD-framework-substrate-service.md`. The arc's closing finding : the
outbox graft is a manual patch for ONE of FOUR substrates the runtime dispatches
into (`EventSourcing::Event`, `CascadeRun`, `OutboundEvent`,
`Governance::Violation`) across seven guard sites, all shaped "is this framework
aggregate in the user's domain? if not, silently do nothing." The other three
have no patch and just degrade — Governance loses authorization audit rows on a
minimal runtime.

Decision locked : ONE injected framework collaborator, per-concern service
facades (`EventSourcingService` et al), one framework-realm store, EventSourcing
first. Step zero is proving a collaborator can be called from inside `&mut self`
dispatch on a single-bluebook boot carrying no EventSourcing chapter. If the
borrow shape fights it, reopen the card rather than force it.
