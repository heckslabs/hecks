# Closing the vendored-lineage gap named in 0030 — scoping, not executed

**Status:** Scoping only. No code changed by this document. Written after
investigating far enough to find the fix touches more than it first
looked like — recorded here so the next session (or this one, on
explicit go-ahead) doesn't have to re-derive it.

## The gap, restated

[0030](0030-rust-mints-its-own-eras-at-boot.md)'s Consequences section (added
this round) names it: a vendoring domain's compiled dispatch table includes a
framework chapter's own commands (`Governance::RoleAssignment.Assign` compiled
directly into `rust/src/generated/banking/merged.rs`), but `rust/host`'s
boot-time self-mint only provisions head-snapshot tables for the TARGET
domain's own aggregates (`Exporter.lineage`'s `capable_aggregates`, scoped to
one bluebook). `bin/project_deploy`'s generated `mint-era` Makefile target is
the only thing that provisions a vendored chapter's own head-1 view today,
by walking `(registry.bluebooks.values - [bluebook]).each { |other|
other.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.
storage_name) } }` (`bin/project_deploy:1764`).

## Why this isn't a small fix

`lineage.capable_aggregates` — the concept this gap is about — is computed
**three separate times**, independently, by design (the same "compile once
per environment, not once total" architecture ADR 0054 names for codegen,
applied here to lineage):

1. **`Exporter.lineage(registry, domain_name)`** (`lib/hecks/projector/
   exporter.rb:45-55`) — the reference. Reads live `Bluebook`/`Aggregate`
   objects off a booted `Runtime::Registry`. This is what `bin/project_rust`'s
   DEFAULT path calls (`bin/project_rust:225`) — the path every real deploy
   uses today (per the deploy-path audit this session already did: `bin/
   project_wasm` only reaches the opt-in Rust-only pipeline when `HECKS_
   PARSER=rust HECKS_CODEGEN=rust` is explicitly set, which `bin/project_
   deploy`'s generated Makefile never sets).
2. **`derive_lineage(ir_text, hecksagon_path)`** (`rust/project_rust_
   pipeline.rb:235-249`) — the opt-in Ruby-orchestrated all-Rust pipeline's
   own re-derivation, from a single chapter's own parsed IR text plus a
   narrow regex scan of its `.hecksagon`'s `persisted_by` binds. It has NO
   access to a vendored chapter's own aggregates today — `chapters` (each
   vendored framework member's own already-parsed `ir_text`) is computed a
   few lines earlier in the same `call` method but never threaded into this
   function.
3. **`rust/build/src/lineage_pass.rs`** — `hecks-build`'s pure-Rust port of
   (2), verbatim per its own header ("ported line for line"). Same blind
   spot as (2), for the same reason.

`spec/project_rust_pipeline_spec.rb` holds (1) and (2) byte-identical for
`examples/banking` specifically — a `uses_framework` domain, deliberately
chosen (per that spec's own `PARITY_DOMAINS` table) to exercise exactly this
kind of cross-chapter shape. `spec/hecks_build_pipeline_spec.rb` holds (2) and
(3) byte-identical the same way. **Extending only (1) breaks (1)-vs-(2)
parity for Banking immediately** — not a hypothetical, a certain, first-CI-run
failure, in the exact spec this migration's own culture built to catch it.
All three have to move together or not at all.

## What the Rust-consumption side actually needs (smaller than it looks)

The good news: `rust/host/src/mint.rs` already has the exact primitive this
needs, private and unused for this purpose. `ensure_first_head` (`mint.rs:
984-993`) is a byte-for-byte port of Ruby's `Lineage#ensure_first_head!`
(`lineage/head_compiler.rb:185-195`) — idempotent (`ensure_head_snapshot`
creates-if-missing, `CREATE OR REPLACE VIEW` for the head view), currently
called only from `hold_first_body`'s loop over the domain's OWN aggregates
(`mint.rs:975-977`).

Closing the Rust side is:
- Add a new `pub(crate) async fn ensure_vendored_heads(client, domain,
  vendored_aggregates)` that loops the same way `hold_first_body` does, over
  a NEW list instead of `aggregates`.
- Call it **unconditionally, every boot** — not only from `hold_first_body`
  (which only runs once, the very first time a domain has no held era) —
  the same reasoning ADR 0030's own Consequences section already gives for
  `mint::ensure_base`: a vendored chapter can be ATTACHED to an
  already-long-running domain later, and an already-past-era-1 domain never
  calls `hold_first_body` again. Wire it in `main.rs`'s boot sequence
  right alongside the existing unconditional `mint::ensure_base` call.
- `ir.rs` needs a new reader for whatever key name the export below picks
  (`lineage_vendored_aggregates` or similar), mirroring `lineage_capable_
  aggregates` (`ir.rs:49-66`) exactly.

This part is genuinely small — a few dozen lines, reusing existing,
already-tested machinery.

## What the three-way export side needs (the actual size)

1. **`Exporter.lineage`**: add a `vendored_aggregates` key —
   `(registry.bluebooks.values - [bluebook]).flat_map(&:aggregates)`,
   unfiltered by `lineage_capable?` (matching the Makefile recipe's own
   unfiltered `other.aggregates.each` exactly — confirmed by reading
   `bin/project_deploy:1616-1633`'s own comment, which never mentions a
   capability filter for the vendored loop). `spec/exporter_spec.rb:85,92`
   have exact `eq(...)` assertions against `Exporter.lineage`'s return shape
   — both need updating for the new key, including the `capable_aggregates:
   []`-only case (line 92) becoming `{capable_aggregates: [], vendored_
   aggregates: []}`.
2. **`derive_lineage`**: needs `chapters` (already computed in `call`,
   `rust/project_rust_pipeline.rb:118-130`) threaded into its signature, and
   for each chapter's own already-parsed `ir_text`, pull `ir[:aggregates]`
   the same way `target_ir`'s own are read, producing `{name:, storage_name:}`
   pairs the identical way `capable_aggregates` already does at line 246.
3. **`lineage_pass.rs`**: the same shape, ported into whatever Rust struct
   currently holds the parsed chapter IRs in `pipeline.rs` (needs reading
   `pipeline.rs`'s own chapter-handling to find the right insertion point —
   not yet done as part of this scoping pass).

**The real open risk, not yet resolved**: ORDER. `Exporter.lineage`'s
`registry.bluebooks.values - [bluebook]` order is Ruby Hash insertion order —
whatever order `uses_framework` calls happened to run in when `.hecksagon`
was `Kernel.load`ed. `derive_lineage`'s equivalent needs `uses_framework_names`
(`rust/project_rust_pipeline.rb:105-110`, from `hecks-parse resolve`'s own
`uses_framework` array) to yield chapters in the SAME order, or the two
sides' `vendored_aggregates` arrays will disagree on ORDER even when they
agree on CONTENT, and the existing specs compare by exact JSON text
(`JSON.pretty_generate`), which is order-sensitive. **Not verified either
way in this pass** — the first real implementation attempt needs to confirm
this before writing a single line of the actual export code, ideally with a
banking-domain repro proving the order already matches (likely, since both
ultimately walk the same `.hecksagon`'s own `uses_framework` calls
top-to-bottom) rather than assuming it.

## Verification this needs before it can be called done

- `spec/exporter_spec.rb` — updated assertions, both the capable-only and
  the (new) vendored case, ideally against a fixture registry that actually
  has TWO bluebooks loaded (today's fixtures may only ever load one — check
  before assuming coverage).
- `spec/project_rust_pipeline_spec.rb` and `spec/hecks_build_pipeline_spec.rb`
  — must stay green for `examples/banking` specifically (both already
  exercise it).
- **A new differential fixture** — nothing today proves Rust's boot-time mint
  provisions a vendored aggregate's head view correctly against a REAL
  Postgres write. `rust/host/tests/fixtures/mint_via_rust_matches_ruby.rb`
  uses a single synthetic bluebook (`DOMAIN = "Ledger"`, confirmed by reading
  it — no `uses_framework` anywhere in it), so it does not exercise this at
  all today. Closing this gap without adding a two-bluebook (owner +
  vendored) scratch scenario to that fixture (or a sibling one) would ship
  an unverified change to real database-provisioning logic — not acceptable
  by this codebase's own standing bar for anything touching era/lineage.
- Golden IR regeneration (`GOLDEN=rewrite` on `spec/ir_golden_spec.rb`) for
  every domain that vendors a framework — Banking is the one already in the
  corpus; check `examples/*/bluebook/*.hecksagon` for `uses_framework` to
  find any others.
- `bin/project_deploy`'s own `mint-era` Makefile recipe stays exactly as-is
  — this closes the SELF-MINT gap, it doesn't retire the Makefile step (a
  vendored chapter attached to a domain deployed with `HECKS_PARSER=rust
  HECKS_CODEGEN=rust bin/project_wasm` — now genuinely reachable per this
  session's #483 — would otherwise have no head table until the NEXT `make
  deploy`, whereas the running binary's own boot-time provisioning closes
  that window immediately). Both mechanisms end up idempotently agreeing;
  neither one is now redundant enough to delete.

## Recommended order, if undertaken

1. Confirm the ordering question above with a live repro (cheapest, decides
   whether the rest needs a sort step or not).
2. `Exporter.lineage` + `spec/exporter_spec.rb` — smallest, most isolated
   piece, verifiable on its own.
3. `derive_lineage` + `lineage_pass.rs` together (they must match each
   other exactly, same as today) — re-run `spec/project_rust_pipeline_spec.
   rb`/`spec/hecks_build_pipeline_spec.rb` immediately after to catch drift
   before doing anything else.
4. `rust/host`: `ir.rs` reader, `mint.rs`'s new `ensure_vendored_heads`,
   `main.rs`'s boot wiring — smallest, most mechanical piece given the
   reusable primitive already exists.
5. The new differential fixture — last, because it's the thing that proves
   1-4 actually agree, not something to write speculatively before the
   shape of what it's proving is settled.
6. Golden IR regen, full suite, ADR 0030 updated again to record the gap as
   closed (superseding this document's own "scoping only" status).

Not started. Flagging step 1 (the ordering question) as the cheapest next
action if this is picked up.
