# Banking, exactly — the arc that makes both runtimes run the flagship correctly

Goal (Chris, 2026-07-27) : make both runtimes run the FULL banking suite
correctly — exact results, every operation exercised, both sides equal.
Design fixes for what's found on the way ; hecks is the reference ; a bug
shared with hecks gets fixed there too.

Baseline @ start : rspec 201/201, cargo green, bin/parity AGREED — at the
CURRENT coverage. The findings below are all inside that green.

## Findings (the survey, 2026-07-27)

1. **The language cannot say arithmetic.** `then_set` admits `to:` and
   `append:` only. Banking bent the domain to fit : `Credit`/`Debit` do
   `then_set :balance, to: :amount` — a credit REPLACES the balance. Both
   runtimes agree (parity green) because both do the same wrong ledger.
   Rule-6 inversion, live in the flagship. Reference : hecks
   `MutationOp::{Increment,Decrement}` (rust/src/runtime/interp_mutations.rs)
   and its Ruby DSL twin.

2. **Process managers are vocabulary without machinery.** DSL + IR + both
   parsers agree on `process_manager "Settlement"` ; NEITHER runtime runs
   one. The saga — banking's stated centrepiece ("the thing that can fail
   halfway") — never happens. Same silence-shape the policies had before
   005f3fb.

3. **The Settlement saga is unrunnable as written.** Transfer carries no
   account references (amount + narrative only) ; the PM's
   `dispatch "Banking::Account.Credit", with: { transfer: :transfer }`
   names neither an account nor an amount. Making PMs run exposes the
   domain hole : Transfer needs `reference_to Account, as: :source /
   :destination` (hecks banking has exactly this shape) and Request must
   carry them ; the PM legs map from the correlated transfer's state.

4. **Queries are outside the parity contract.** bin/run + the Rust script
   runner execute command steps only ; no query is ever compared. Seven
   query declarations (where / order_by / desc / limit / parameterized
   `lt: :floor`) are unverified behaviour on both sides.

5. **Debit/Credit ignore frozen status.** Freeze is a lifecycle state, but
   Credit/Debit are not transitions and carry no status given — a frozen
   account transacts freely in both runtimes. "Stop an account moving" is
   the stated goal of Freeze ; it does not.
   (hecks' banking example has the same class of hole — fix both.)

6. **Cross-domain policies target domains that never load** (Compliance,
   Notifications). Reactions are recorded undelivered — by design — but
   the parity script never ASSERTS the recorded shape for these ; pin it.

## The layers (each : Ruby first, Rust projection, corpus pin, commit)

L1 `increment:`/`decrement:` — DSL command_builder + IR::Mutation op +
   Ruby interpreter (instance/mutations) → Rust ir/parser/mutations.rs →
   banking Credit/Debit corrected → parity steps pin RUNNING BALANCES
   (credit 10000, debit 2500 → 7500, refusals leave 7500 untouched).

L2 Frozen-account gate — domain fix : `given("the account is open")
   { status == "open" }` on Credit + Debit (status readable by givens ?
   verify ; hecks givens read state). Parity : freeze then debit → refusal
   on both sides. Mirror the same gate into hecks examples/banking
   (Withdraw/Deposit ungated there too).

L3 Process-manager execution — Ruby runtime grows a PM engine mirroring
   hecks semantics : instance keyed by `correlates_by` value, born on
   `starts_on` event, per-`on` handler = (optional state transition) +
   dispatches with `with:` mapping from event payload + PM correlation ;
   ends on `ends_on`. Record every PM step in a `sagas:` section of the
   run contract (like reactions:). Project to Rust. Banking's Transfer
   gains source/destination references so the saga can actually move
   money ; the full happy path AND the compensating leg (freeze the
   destination mid-flight) go into the parity script.

L4 Query steps in the contract — script grammar gains
   `{ "query": "Banking::Account.Open", "args": {…} }` ; bin/run + Rust
   runner execute + emit `queries:` results ; all seven banking queries
   pinned incl. order_by/desc/limit and the parameterized floor.

L5 Exhaustive matrix — every command's happy path + EVERY refusal gate,
   entity command (LedgerEntry.Reverse) + entity query, every lifecycle
   transition incl. illegal moves, reaction assertions for undeliverable
   cross-domain policies. rspec examples pin Ruby as RIGHT (dsl_spec
   culture) ; parity pins Rust EQUAL.

L6 hecks mirrors — the wprobe payload-gate acceptance (live dispatch
   accepts out-of-set scalar ; interp judges correctly in isolation —
   cause unfound, HANDOVER §NOT-working), frozen-gate for hecks banking,
   plus anything L1-L5 surfaces that hecks shares.

## Standing constraints

- Ruby is truth ; the exporter converts shapes ; never bend a bluebook to
  a projection (finding 1 is the cautionary tale).
- Zero warnings, zero failing tests, specs do no IO outside spec/adapters.
- hecksagain commits tell the finding-first story like the existing log.
- hecks commits ride feat/fixtures-to-policies conventions (antibody
  markers, parity 389/389, workspace builds).
