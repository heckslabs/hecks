# Option 2 scoping — making `hecks-codegen` the sole Rust generator

**Status:** Scoping addendum to 0054, not a decision. 0054 kept both generators
(status quo, Option 3) and named Option 2 — "make `hecks-codegen` the sole
generator, retire `rust/project`" — as the direction to move in *if* the
two-copy tax ever outweighs the porting cost, while stating plainly that the
migration was "real, unscoped work with no immediate driver and is not
decided or started." This document scopes that work. It recommends nothing
and starts nothing — no code changes were made producing it.

## Summary of the finding

The porting cost is smaller than 0054's own text implies for the codegen
*algorithm* itself — `spec/codegen_parity_spec.rb` already proves
`hecks-codegen` byte-identical to `rust/project/*.rb` for every real corpus
member it covers, and every piece of orchestration logic that used to be
Ruby-only (the append-optional-fields derivation, the lineage derivation,
`rust_string_literal`, domain-name validation, sidecar writing, Cargo/mod.rs
sync) has *already been ported to Rust once*, independently, inside
`rust/build/src/*.rs` for the Stage 8 Ruby-free capstone. Retiring
`rust/project` would not require inventing new ports; it would require
either reusing `rust/build`'s existing Rust ports or re-deriving Ruby-side
equivalents that call `hecks-codegen` as a subprocess the way
`rust/project_rust_pipeline.rb` already does.

The real, unscoped cost is concentrated in exactly the three places 0054
named — `bin/project_rust`'s default path, `bin/rust_coverage`'s manifest
dependency, and the generator-specific test/spec scaffolding around
`rust/project/*.rb` — plus one real coverage gap this investigation
surfaced that 0054 did not mention: **`examples/roster` (and
`examples/compliance`, for the whole-file check) have never been proven
byte-identical between the two generators**, despite being part of the CI
drift-check corpus.

## Finding A — `bin/project_rust`'s default path and `hecks-codegen`'s actual input contract

`bin/project_rust`'s default (no-env-var) path is the `else` branch at
`bin/project_rust:122-577`. It does three things `hecks-codegen` cannot do
itself and would still have to do exactly as today:

1. **Boot Ruby and build the live `ir` Hash.** `Kernel.load`s the domain's
   persistence/extraction ports, adapters, `.bluebook`/`.hecksagon`/
   `translations/*.bluebook` files into a `Runtime::Registry`
   (`bin/project_rust:150-201`), then calls
   `Hecks::Projector::Exporter.call`/`.lineage`/`.translations` and reads
   the raw `source_text` off disk (`bin/project_rust:206-236`). Nothing in
   `hecks-codegen` parses `.bluebook`/`.hecksagon` — ADR 0023 keeps that
   permanently Ruby-only for this path (the Rust-native alternative is
   `hecks-parse`, a *different* subprocess, not `hecks-codegen`) — so this
   half is unaffected by Option 2 either way.
2. **Apply `RustProjection::Projector.mark_append_optional_fields!` per
   aggregate before generating.** This is the one load-bearing precondition
   on `hecks-codegen`'s input shape. `rust/codegen/src/main.rs`'s
   `run_domain`/`run_full` read `ir.json` via `Json::parse` and hand it
   straight to `domain_generator::generate` — no mutation pass of any kind
   (confirmed by reading `rust/codegen/src/main.rs:104-142`, `205-330`;
   there is no call there resembling `mark_append_optional_fields!`).
   `spec/codegen_parity_spec.rb`'s own header says this explicitly:
   "`mark_append_optional_fields!` (mutations.rb) is STILL NOT PORTED" into
   `hecks-codegen` (`spec/codegen_parity_spec.rb:65`). The spec's own
   fixture-building code depends on this silently: it calls Ruby's
   `RustProjection::DomainGenerator.call(ir, ...)` FIRST — which mutates
   `ir` in place via `domain_generator.rb:164`'s own
   `Projector.mark_append_optional_fields!(aggregate, ...)` call — and only
   *then* serializes that same, now-mutated `ir` Hash to the `ir.json` it
   feeds `hecks-codegen` (`spec/codegen_parity_spec.rb:196-200`). So: **yes,
   `hecks-codegen` reads exactly the `ir.json` shape Ruby produces today —
   but only the POST-derivation shape**, and today's on-disk
   `rust/src/generated/<domain>/ir.json` already *is* that post-derivation
   shape, because `RustProjection::DomainGenerator.call` mutates `ir` at
   line 164 before writing it out at `domain_generator.rb:835-836`. There
   is no seam requiring Rust's own parser output specifically — this
   confirms `bin/project_rust`'s own header comment
   (`bin/project_rust:104-110`) that `hecks-codegen` "only reads the
   `ir.json` SHAPE, never Ruby's own live IR objects."
3. **Write `metadata.rs`/`ir.json`/`manifest.json` per generated directory,
   and the root `mod.rs`/`Cargo.toml` feature-sync tail.**
   `RustProjection::DomainGenerator.call` writes all three sidecars itself
   (`domain_generator.rb:817-849`); `bin/project_rust`'s own tail
   (`bin/project_rust:460-577`) does the Cargo-feature/`mod.rs` bookkeeping
   separately, once, after every chapter is generated. `hecks-codegen`
   writes none of the three sidecars — `rust/codegen/src/main.rs`'s own
   `run_full` header says so explicitly ("NOT written here:
   `metadata.rs`/`ir.json` per directory... and `manifest.json`",
   `rust/codegen/src/main.rs:187-200`).

**What already exists to close this gap.** `rust/project_rust_pipeline.rb`
(the opt-in `HECKS_PARSER=rust HECKS_CODEGEN=rust` path,
`bin/project_rust:119-121`) already does exactly this shape of
orchestration around `hecks-codegen full` — it calls
`derive_append_optionals` (a thin Ruby wrapper around the same
`mark_append_optional_fields!`, `rust/project_rust_pipeline.rb:180-201`),
writes `ir.json`/`metadata.rs` itself (`write_sidecars!`,
`rust/project_rust_pipeline.rb:330-360`), and does its own
`mod.rs`/`Cargo.toml` sync tail (`sync_mod_and_cargo!`,
`rust/project_rust_pipeline.rb:365-448`) — deliberately re-implemented
rather than shared with `bin/project_rust`'s own tail, so the two paths'
correctness can be verified independently (its own header,
`rust/project_rust_pipeline.rb:406-412`). Separately, `rust/build`
(`hecks-build`) has already ported every one of these Ruby helpers to pure
Rust: `optional_pass.rs` (mark_append_optional_fields!),
`lineage_pass.rs` (Exporter.lineage), `sidecars.rs` (rust_string_literal +
ir.json/metadata.rs writing), `cargo_sync.rs` (valid_domain_mod_name? +
the mod.rs/Cargo.toml tail) — confirmed by direct comment cross-reference
(`rust/build/src/cargo_sync.rs:48`, `rust/build/src/sidecars.rs:19`,
`rust/build/src/optional_pass.rs:1-5`). None of that Rust code is
reachable from `bin/project_rust` today (it's a separate crate,
`rust/build`, built for `hecks-build`'s own standalone binary), but its
existence means Option 2's version of this step is a genuine port-and-wire
job, not new design.

**Manifest.json is the one piece with no existing port anywhere** — see
Finding C.

## Finding B — the deploy parity gate is generator-agnostic, but wired through `bin/project_rust`'s default path

`bin/project_deploy` generates a `verify-parity-<LogicalId>` Makefile
target (`bin/project_deploy:2236-2274`) that runs `bin/rust_conformance
<domain> spec/corpus/<name>.json $(WASM)` against `$(WASM)` — the exact
artifact `build-<LogicalId>:` (`bin/project_deploy:2162-2178`) just
compiled. `bin/rust_conformance` itself has zero `RustProjection::`
dependency (confirmed by grep — its only two matches,
`bin/rust_conformance:34,110`, are comments describing what
`bin/project_rust` produces, not a code dependency) — it diffs a Ruby
corpus script's output against whatever the compiled artifact's stdin/
stdout CLI answers, which makes the gate itself entirely
generator-agnostic. `spec/project_deploy_parity_gate_spec.rb` confirms
this both structurally (the generated Makefile just names
`bin/rust_conformance`/`$(WASM)`, `spec/project_deploy_parity_gate_spec.rb:70-76`)
and functionally (real pass/fail against real compiled `.wasm` artifacts,
`spec/project_deploy_parity_gate_spec.rb:157-181`, with no reference to
which generator built them).

The one real coupling: `build-<LogicalId>:` gets `$(WASM)` by shelling out
to `bin/project_wasm` (`bin/project_deploy:2175`), and `bin/project_wasm`
itself calls `bin/project_rust <domain>` directly and unconditionally
(`bin/project_wasm:33`, no env vars set — always the default path). So the
deploy parity gate needs **zero changes of its own** under Option 2; it
inherits whatever `bin/project_rust`'s default path produces, transitively,
through `bin/project_wasm`. The only requirement carried forward is the one
Finding A already names: `bin/project_wasm`'s own tail
(`bin/project_wasm:57-63`) copies `rust/src/generated/<domain>/ir.json` into
`rust/dist/<domain>.ir.json` if it exists — non-fatal if absent, but
`rust/host/src/web.rs`'s `HECKS_IR_PATH` reader depends on that file being
real (comment cross-reference at `rust/host/src/web.rs:6`), so `ir.json`
still has to get written by *something* after switching generators.

## Finding C — `bin/rust_coverage`'s manifest dependency is the real cost center

`bin/rust_coverage` is a real, exit-code-gated CI check
(`.github/workflows/ci.yml:316-354`, six domains: pizzas, embryonaut,
governance, identity, banking, meta). It has two modes
(`bin/rust_coverage:60-90`):

- **Manifest mode (today's default for every in-checkout domain).** Reads
  `rust/src/generated/<domain>/manifest.json`, one entry per
  generate/skip decision `domain_generator.rb` made, WITH a per-instance
  `reason` string (`bin/rust_coverage:347-350`).
- **Fallback mode (today: Embryonaut only, whose bluebook source isn't in
  this checkout at all).** Regex-scans `registry.rs` for quoted dispatch
  keys (`bin/rust_coverage:337`) to answer only "is this verb routed" —
  and is *provably, admittedly weaker* in three specific ways, all
  documented in the tool's own header and code:
  1. **No per-instance reason text** — every fallback finding gets a
     generic `"fallback mode: no \"<verb>\" match arm in registry.rs"`
     reason (`bin/rust_coverage:211-214`, `230-233`, `248-249`), never the
     real Ruby-generator prose the allowlist matches against (see below).
  2. **Policy/process-manager routing is UNVERIFIABLE, by design** — every
     policy and process manager gets `generated: nil` (an UNKNOWN bucket,
     excluded from the exit-code gate), because the generated policy
     table carries event/target-verb data, never the policy's own name
     (`bin/rust_coverage:283-299`).
  3. **Every declared `read_model` is unconditionally reported as a
     `gap_class: "whole_kind"` GAP**, with no way to tell an actually-
     generated read model (Banking's `AccountsByKind`, which real
     manifest-mode coverage shows IMPLEMENTED) from a genuinely
     ungenerated one (`bin/rust_coverage:271-277` — this row is built
     unconditionally from `payload.fetch(:read_models)`, with no check
     against `registry.rs` content at all, because the generated read-model
     table carries no per-model routable string).

Confirmed by reading `rust/build/src/pipeline.rs:188` and
`rust/project_rust_pipeline.rb`'s own header
(`rust/project_rust_pipeline.rb:65-76`): **`manifest.json` is a named,
deliberate gap in *both* Rust-side orchestrators already built** (the
opt-in pipeline and `hecks-build`), not merely unattempted in
`hecks-codegen` itself. Both give the identical reasoning: porting ~15 call
sites' worth of skip-reason bookkeeping "would duplicate logic
commands.rs/queries.rs/read_models.rs/etc. already compute for the REAL
decision... not add new correctness coverage."

Under Option 2 — `rust/project`'s `domain_generator.rb` deleted, no
Ruby-side generation ever runs — **every domain, not just Embryonaut,
degrades to fallback mode permanently**, unless a manifest-writer is built
somewhere in the `hecks-codegen`/`hecks-build` call graph. That has two
further consequences beyond "coverage gets fuzzier":

- **`bin/rust_coverage`'s `ALLOWLIST`** (`bin/rust_coverage:359-499`)
  matches specific `reason_match` regexes against Ruby-generator-authored
  prose — e.g. `/\Aoptional argument feeds a non-optional target: .+ —
  not generated yet\z/` (quoting `rust/project/commands.rb`'s own
  `#optional_source_mismatches` comment,
  `bin/rust_coverage:416-417,432-433`) and `/\A(declares |where clause
  on )/` (quoting `rust/project/queries.rb`'s `query_skip_reason`,
  `bin/rust_coverage:454-455,462-463`). Fallback-mode findings never
  produce this text (they only ever say `"fallback mode: ..."`), so **none
  of today's allowlist entries would ever match again** — every currently-
  DEFERRED finding across banking/meta (documented at
  `.github/workflows/ci.yml:329-354` as the specific, hard-won reason CI
  is green today) would flip to an unallowlisted GAP and fail the build,
  the moment the underlying domain has no `manifest.json`.
- **CI's own drift-check step**
  (`.github/workflows/ci.yml:274-300`) regenerates
  banking/compliance/pizzas/roster and diffs the committed
  `rust/src/generated/` tree; it does not touch `manifest.json` directly,
  but it establishes that the checked-in tree today *is* Ruby-generator
  output byte for byte. If `bin/project_rust`'s default flips generators,
  this step's own comparison baseline (the already-committed tree) has to
  be regenerated once, in full, and re-committed with `hecks-codegen`'s
  output — safe only for domains `spec/codegen_parity_spec.rb` has already
  proven byte-identical (see the Risks section — `roster` is not one of
  them).

**No existing code anywhere writes a `hecks-codegen`/`hecks-build`
manifest.json equivalent.** This is the one piece of Finding A/C that has
no prior-art Rust port to reuse — it is new work, not porting.

## Finding D — other consumers of Ruby-generator-specific internals

Grepped `RustProjection::` and `domain_generator` across the whole repo,
outside `rust/project/` and `bin/project_rust` themselves:

- **`lib/hecks/projector.rb:7,50`** — comment-only. It exists to
  disambiguate `Hecks::Projector` (the real IR exporter, `lib/hecks/
  projector/exporter.rb`) from `RustProjection` (this generator) by name;
  no code dependency.
- **`rust/project_rust_pipeline.rb`** — already discussed in Finding A;
  calls `RustProjection::Projector.valid_domain_mod_name?`,
  `.mark_append_optional_fields!`, `.rust_string_literal` directly. This
  file *itself* would need to either keep a minimal slice of
  `rust/project` alive (just `naming.rb`+`mutations.rb`'s
  `mark_append_optional_fields!`, not the whole generator) or be rewritten
  against `rust/build`'s already-Rust equivalents.
- **`spec/codegen_parity_spec.rb`, `spec/support/ruby_codegen_prelude.rb`,
  `spec/rust_project/*.rb`** (bridging/closed_set_fielded/constraints/
  creates_owner/exemplar/naming_landmines/queries/reactions_merge specs) —
  these are the differential-harness test scaffolding *for* `rust/project`
  itself. They call dozens of `RustProjection::Projector.emit_*`/
  `rust_ident`/etc. functions directly to build a reference output to diff
  against `hecks-codegen`'s. Under Option 2 these don't get "ported" — they
  get **deleted**, along with `rust/project`, because there is no second
  generator left to diff against. `spec/codegen_parity_spec.rb` itself
  becomes meaningless the day `rust/project` is gone (nothing to compare
  `hecks-codegen`'s output *to*) and would need to be replaced by
  something that instead diffs `hecks-codegen`'s output against the
  semantics corpus (`spec/corpus/semantics`) or against the previously-
  committed tree, not against a second implementation.
- **`rust/host/src/{ir.rs,web.rs,bin/lineage_harness.rs}`,
  `rust/src/kernel/{dispatch,mod,orchestrate,repository,routing}.rs`,
  `rust/src/exemplar/{json,registry}.rs`** — every one of these
  `domain_generator` matches is a **comment-only design-rationale
  reference** ("matches `domain_generator.rb`'s own X"), not a runtime or
  build-time dependency on Ruby's generator internals. Confirmed by
  reading each match in context. No change needed to any of these files.
- **`rust/codegen/src/{bridging,domain_generator,json_codec,main,prelude,
  registry,types}.rs`, `rust/build/src/sidecars.rs`** — these are
  `hecks-codegen`'s/`hecks-build`'s own ports, i.e., the intended
  replacement, not a consumer needing further work.

**Conclusion for Finding D: no hidden fourth consumer.** The full set of
things Option 2 touches is exactly what 0054 already named
(`bin/project_rust`, the deploy parity gate, `bin/rust_coverage`) plus the
generator's own test harness (`spec/codegen_parity_spec.rb` and its
support files), which 0054 didn't call out by name but is an unavoidable
casualty of deleting one side of a differential test.

## Concrete scope, if this were undertaken

| # | Item | Size | Files touched | Notes |
|---|------|------|----------------|-------|
| 1 | Write a `hecks-codegen`/`hecks-build`-side manifest.json writer (per-construct generate/skip decisions, with reason text) | **Large** | New: manifest-tracking module in `rust/codegen/src/domain_generator.rs` (or a new `manifest.rs`) mirroring `rust/project/domain_generator.rb`'s ~15 `manifest_entry` call sites (`rust/project/domain_generator.rb:171-795`) | No prior art exists for this piece specifically (Finding C). Must reproduce not just presence/absence but the *exact reason strings* `bin/rust_coverage`'s `ALLOWLIST` regexes match, or the allowlist has to be rewritten and re-verified against every currently-deferred finding across banking/meta/pizzas/governance/identity. |
| 2 | Rewrite `bin/rust_coverage`'s `ALLOWLIST` against whatever reason-text convention item 1 produces, and re-verify every currently-DEFERRED finding is still deferred | **Medium** | `bin/rust_coverage:359-499` | Blocked on item 1's exact string output. Six CI domains must each independently come back 0-GAP again (`.github/workflows/ci.yml:316-354`). |
| 3 | Give `bin/project_rust`'s default path a `hecks-codegen`-backed body: keep the existing Ruby IR-building half (`bin/project_rust:122-236`) unchanged, replace the three `RustProjection::DomainGenerator.call` invocations with `hecks-codegen full`/`domain` subprocess calls plus a sidecar-writer, keep (or replace with `rust/build`'s ported equivalent of) the root `mod.rs`/`Cargo.toml` tail | **Medium** | `bin/project_rust:122-577`; likely folds in logic from `rust/project_rust_pipeline.rb:180-448` and/or calls `hecks-build` directly instead of hand-rolling the orchestration a third time | `rust/project_rust_pipeline.rb` already proves most of this shape works today for the opt-in path; the remaining question is whether to reuse it, retire it in favor of shelling out to `hecks-build` itself, or write a third variant — a real design choice this document does not resolve. |
| 4 | Extend `spec/codegen_parity_spec.rb`'s corpus (or an equivalent semantics-level check) to cover `examples/roster` and `examples/compliance` for the WHOLE-FILE comparison, not just the prelude-only one | **Medium** | `spec/codegen_parity_spec.rb:131-169` | See Risks — today `WHOLE_FILE_MEMBERS` is `pizzas identity governance compliance banking bluebook_language` (`spec/codegen_parity_spec.rb:169`) but `compliance` there is `examples/compliance` loaded via a different path than the one CI's drift-check regenerates for real (`.github/workflows/ci.yml:276`); `roster` has no `CODEGEN_CORPUS_MEMBERS` entry at all (`spec/codegen_parity_spec.rb:131-136`). Must close both before CI's drift-check step can trust `hecks-codegen` output for those domains. |
| 5 | Re-baseline the CI drift-check step's committed tree (`rust/src/generated/`, `rust/Cargo.toml`) against `hecks-codegen`-produced output, once, for every in-checkout domain | **Small**, high-blast-radius | `.github/workflows/ci.yml:274-300`, the entire committed `rust/src/generated/` tree | Mechanical once items 1-4 are done and item 3 is wired in; the risk is entirely in *when* it's safe to do, not in doing it. |
| 6 | Retire `rust/project/*.rb` (17 files, ~7.4k lines) and its direct test suite | **Small** (deletion) but **only safe after** items 1-5 | `rust/project.rb`, `rust/project/*.rb`, `spec/rust_project/*_spec.rb`, `spec/support/ruby_codegen_prelude.rb`, `spec/codegen_parity_spec.rb` (replace or delete — nothing left to diff against) | `rust/project_rust_pipeline.rb` also becomes dead code once item 3 lands (it existed only to prove the opt-in path before it became the default) — likely deleted alongside, or kept only if item 3 chooses to keep calling it directly. |
| 7 | Decide `rust/project_rust_pipeline.rb`'s and `rust/build`'s fate relative to the new default `bin/project_rust` path | **Small**, design decision not code | `rust/project_rust_pipeline.rb`, `rust/build/*` | If `bin/project_rust`'s new default shells out to `hecks-build` directly (item 3's third option), the opt-in `HECKS_PARSER=rust HECKS_CODEGEN=rust` env-var toggle in `bin/project_rust:119` becomes redundant (there'd be only one path) — a further, real simplification, but a design change 0054 never asked for and this document does not recommend. |

**Rough total:** two Large-ish items (1, and the design/plumbing work
folded into 3), the rest Medium/Small — this is a multi-week effort for one
engineer familiar with both crates, dominated entirely by item 1 (the
manifest-writer) and item 4 (closing the roster/compliance parity gap
*before* trusting a wholesale re-baseline).

## Genuine unknowns and risks

- **`examples/roster` has never been proven byte-identical between the two
  generators**, at any level (prelude or whole-file) —
  `spec/codegen_parity_spec.rb:131-136`'s `CODEGEN_CORPUS_MEMBERS` simply
  has no `roster` entry, yet CI's drift-check step
  (`.github/workflows/ci.yml:300`) regenerates and trusts
  `examples/roster` via the Ruby generator today. Switching the default
  generator without first adding roster to the parity corpus risks
  silently shipping a first-time divergence in a domain that has never
  been differentially tested at all. `docs/decisions/0037-...md`'s own
  Finding 2 already recorded that `examples/roster`'s committed generated
  tree has gone *stale* at least once before, unnoticed, so this domain
  has a track record of being under-watched.
- **`examples/compliance`'s parity coverage is via `domain_ir` loaded
  in-process from `examples/compliance/bluebook/compliance.bluebook`**
  (`spec/codegen_parity_spec.rb`'s `CODEGEN_CORPUS_MEMBERS` entry), which
  may or may not be bit-for-bit the same load path CI's drift-check step
  exercises through `bin/project_rust examples/compliance` directly
  (`.github/workflows/ci.yml:276`) — worth confirming, not assumed here.
- **`spec/project_rust_pipeline_spec.rb`'s own `PARITY_DOMAINS`**
  (`spec/project_rust_pipeline_spec.rb:77-80`) — proving the opt-in
  Rust-parser pipeline byte-identical to the Ruby default — covers only
  `pizzas` and `banking` (plus `meta`, always). `spec/
  hecks_build_pipeline_spec.rb`'s `HB_PARITY_DOMAINS`
  (`spec/hecks_build_pipeline_spec.rb:69-71`) covers the same two. Neither
  proves `compliance` or `roster` through the *orchestration* layer either
  — a second, independent gap from the codegen-only one above, since even
  a manifest-writer and a correct `hecks-codegen` don't help if the
  orchestration around it (chapter resolution, `uses_framework`
  attachment, lineage/translations derivation) has never been exercised
  for those two domains.
- **The manifest-writer (item 1) is genuinely new design work**, not a
  port — `rust/project/domain_generator.rb`'s ~15 `manifest_entry` call
  sites are interleaved throughout the generation logic itself (each skip
  decision is recorded at the exact point it's made,
  `rust/project/domain_generator.rb:171-795`), so replicating it in
  `hecks-codegen`'s `commands.rs`/`queries.rs`/`read_models.rs`/etc. means
  threading an accumulator through code that, per both existing headers
  (`rust/codegen/src/main.rs:187-200`, `rust/build/src/pipeline.rs:188`),
  was deliberately *not* structured to carry one. This is real,
  non-mechanical work, not a mechanical translation the way the rest of
  `hecks-codegen` already was.
- **`bin/rust_coverage`'s allowlist rewrite (item 2) has a correctness
  trap**: it is tempting to widen `reason_match` patterns to be
  generator-agnostic (e.g., match on `gap_class` alone, dropping the
  quoted-prose requirement). The tool's own stated governing rule is that
  "a finding only belongs [in the allowlist] because it is ALREADY
  documented elsewhere as a deliberate deferral — never because this tool
  happened to find it missing and a clean run looked nicer"
  (`bin/rust_coverage:150-156`). Loosening the match to keep CI green
  through the transition, without first confirming each loosened rule
  still points at a real, still-true citation, would quietly recreate the
  exact failure mode this tool exists to prevent.
- **No timeline pressure exists for any of this.** 0054's own Decision
  section is unchanged by this document: nothing here argues the two-copy
  tax currently outweighs this cost, only that the cost, now itemized, is
  concrete rather than open-ended.

## Recommended order, if undertaken

1. Add `roster` (and confirm `compliance`) to
   `spec/codegen_parity_spec.rb`'s `CODEGEN_CORPUS_MEMBERS`/
   `WHOLE_FILE_MEMBERS` first, standalone, independent of everything else
   — this is valuable today, under the status quo, regardless of whether
   Option 2 ever happens, and de-risks every later step.
2. Build the manifest-writer (item 1) against `hecks-codegen` (not
   `hecks-build` — the smaller, already-tested crate), and prove it
   produces `bin/rust_coverage`-compatible output for every domain
   currently in manifest mode, before touching `bin/project_rust` at all.
3. Rewrite `bin/rust_coverage`'s allowlist (item 2) against that output,
   confirmed 0-GAP on all six CI domains, still running the OLD
   `bin/project_rust` default (Ruby) in parallel via a flag or a temp
   script — i.e., prove the coverage tool works against `hecks-codegen`
   manifests before anything depends on it exclusively.
4. Only then flip `bin/project_rust`'s default (item 3), choosing at that
   point whether to route through `rust/project_rust_pipeline.rb`,
   `hecks-build` directly, or a new thin wrapper.
5. Re-baseline CI's drift-check tree (item 5) as the very last step, once
   3 and 4 are both proven stable locally against a clean checkout.
6. Delete `rust/project` and its direct test suite (item 6) only after
   step 5's CI run is green on the retargeted default path, not before.
