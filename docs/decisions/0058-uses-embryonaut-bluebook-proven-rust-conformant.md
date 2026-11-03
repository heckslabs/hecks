# `uses_embryonaut_bluebook` proven Rust-conformant via a minimal vendoring demo domain

**Status:** Shipped. New example corpus member `examples/embryonaut_vendoring_demo` (a
consuming domain, `Gadget`) plus a vendored package
`examples/embryonaut_vendoring_demo/vendor/embryonaut_bluebooks/widgets` (a `Widget`
aggregate) attached via `uses_embryonaut_bluebook "widgets"`. Real code changes, found
necessary while proving this, not merely documented as gaps: `rust/parser/src/parse/
{hecksagon.rs,chapter.rs}` and `rust/parser/src/main.rs` (the opt-in Rust-native pipeline
learns to resolve `uses_embryonaut_bluebook` the same way it already resolves
`uses_framework`); `bin/project_rust` (the default path's own generated-file header
wrongly hardcoded `uses_framework` for every attached chapter regardless of which DSL
word actually attached it); `lib/hecks/corpus.rb` + `spec/corpus_rust_spec.rb` +
`spec/codegen_parity_spec.rb` (a `:vendored` corpus kind and `rust_vendored_chapters`,
mirroring `:framework`/`rust_framework_chapters`, which did not exist because nothing had
ever exercised this attachment mechanism for real); `bin/model_check` +
`spec/model_check_spec.rb` + `spec/parser_parity_spec.rb` (each built its own throwaway
`Runtime::Registry.new` with no `root:`, which `EmbryonautBluebook.load!` requires and a
`uses_framework`-only corpus never needed).

## What this proves

This session's own earlier research established that `uses_framework` (Banking's
`Governance`/`Identity`) is real, CI-enforced, and byte-exact-verified on both Ruby and
Rust — but `uses_embryonaut_bluebook` (`lib/hecks/embryonaut_bluebook.rb`), a structurally
identical, SEPARATE mechanism for vendoring a bluebook chapter from outside this gem
entirely, had zero test, fixture, or golden IR anywhere in this repo, and no real project
on this machine calls it in a live `.hecksagon`. The claim that it "should work the same
way" rested entirely on reading `bin/project_rust`'s own default path being GENERIC over
`target_registry.bluebooks.keys - [target_domain_name]` — never on having actually run it.

It has now actually been run, through every layer that mattered:

- **Real Ruby boot** (`Hecks.boot`): dispatches on the consuming domain's own aggregate
  (`EmbryonautVendoringDemo::Gadget.Register`/`.Activate`) and on the vendored aggregate
  reached through the exact same booted registry (`Widgets::Widget.Create`/`.Retire`),
  including a `given` refusal on each side.
- **The default Rust codegen path** (`bin/project_rust examples/embryonaut_vendoring_demo`,
  no env vars): generates `rust/src/generated/embryonaut_vendoring_demo/` AND
  `rust/src/generated/widgets/` — the same shape Governance/Identity get for Banking — and
  the merged `Store`/`dispatch_by_name` in `embryonaut_vendoring_demo/merged.rs` embeds
  `widget: crate::kernel::InMemoryRepository<crate::generated::widgets::widget::Widget>`
  alongside its own `gadget` field, with `dispatch_by_name` routing both
  `"EmbryonautVendoringDemo::Gadget.*"` and `"Widgets::Widget.*"` verbs against it — the
  identical dispatch-table-merge shape `banking/merged.rs` already proves for
  `uses_framework`.
- **The opt-in, all-Rust `hecks-parse`/`hecks-codegen` pipeline** (`HECKS_PARSER=rust
  HECKS_CODEGEN=rust bin/project_rust examples/embryonaut_vendoring_demo`): did NOT work
  on first attempt (see "A real gap found and fixed" below) — now produces byte-identical
  output to the default path, verified by `spec/project_rust_pipeline_spec.rb`'s own
  `PARITY_DOMAINS`, the same differential proof Banking gives `uses_framework`.
- **The real conformance/parity harness**: a compiled Rust binary, run against a
  hand-authored corpus fixture and against 5 `Hecks::Fuzzing::SequenceGenerator`-generated
  random sequences, both agreeing byte-for-byte with Ruby across instances, events,
  refusals, reactions, sagas, and queries.

## A real gap found and fixed: the opt-in Rust-native pipeline never resolved `uses_embryonaut_bluebook`

Adding `examples/embryonaut_vendoring_demo` to `PARITY_DOMAINS` first failed outright.
`rust/parser`'s own keyword table (`keywords.rs`) already admitted `uses_embryonaut_bluebook`
as a shape-matched word, but `rust/parser/src/parse/hecksagon.rs::apply` only ever
collected `uses_framework` names into an accumulator (`uses_framework_names`) for
`hecks-parse resolve` to report back; `uses_embryonaut_bluebook` fell through to the
generic "shape-matched, dropped" open-vocabulary bucket alongside `persisted_by`. This
meant `rust/project_rust_pipeline.rb`'s orchestration — which resolves every
`uses_framework`-named chapter through `Hecks::Framework.members` and compiles it in —
had no way to discover a vendored chapter at all: it would have silently generated a
consuming domain with the vendored chapter simply missing, a real, silent divergence from
the default path, not a hypothetical one.

Fixed at the same layer `uses_framework` itself is handled, not worked around:
`hecksagon.rs::apply` gained a second accumulator (`vendored_bluebook_names`) and a
`"uses_embryonaut_bluebook"` match arm; `chapter.rs::resolve_uses_framework` was renamed
`resolve_hecksagon_dependencies` and now returns both name lists from the one scan;
`main.rs`'s `hecks-parse resolve` JSON output gained a `"uses_embryonaut_bluebook"` key
alongside `"uses_framework"`; `rust/project_rust_pipeline.rb::call` resolves each named
vendored package's own `<domain>/vendor/embryonaut_bluebooks/<name>/bluebook/*.bluebook`
files (sorted, mirroring `EmbryonautBluebook.load!`'s own resolution exactly), checks the
declared chapter name against `Naming.pascal(name)`, and appends the result onto the same
`chapters` array the framework loop already builds — every downstream step (codegen,
`mod.rs`/Cargo feature sync, sidecar writing) is already generic over that array and
needed no further change.

A second, smaller instance of the same "never exercised, never generalized" pattern
surfaced in the DEFAULT path itself: `bin/project_rust`'s own generated `.rs`/`metadata.rs`
header comment hardcoded `"#{domain} (uses_framework #{chapter_name.inspect})"` for
*every* attached chapter, regardless of which DSL word actually attached it — cosmetically
wrong for `widgets` (labeled `uses_framework "Widgets"` where it should say
`uses_embryonaut_bluebook "widgets"`), and the exact mismatch `spec/project_rust_pipeline_spec.rb`
caught as a real byte-diff against the now-correct opt-in path. Fixed by checking the
target's own `Hecksagon#vendored_bluebooks` list (resolving `Naming.pascal` the same way)
before falling back to the original `uses_framework` wording — a fallback that leaves
every existing corpus member's own generated comment untouched, confirmed by regenerating
`examples/banking`/`pizzas`/`roster`/`compliance` and diffing byte-for-byte against HEAD
(no change).

## A parallel gap in this repo's own corpus accounting, closed the same way

`Hecks::Corpus` (`lib/hecks/corpus.rb`) — the one table every corpus-walking spec reads —
had a `:framework` kind and a `rust_framework_chapters` method accounting for a
`uses_framework`-attached chapter's own generated Rust module (no `merged.rs`, no Cargo
feature, attributed to whichever domain last regenerated it), but no equivalent for
`uses_embryonaut_bluebook`. The moment `widgets/` existed as a real generated module,
`spec/corpus_rust_spec.rb`'s "sends every generated module to exactly one bucket" and
`spec/corpus_accounting_spec.rb`'s "covers every sweepable domain with some kind" both
failed for real — `widgets` (and its own vendored source directory) had nowhere to go.
Closed by adding a `:vendored` `DIRECTORY_KIND` (`examples/*/vendor/embryonaut_bluebooks/*`)
and a `rust_vendored_chapters` method mirroring `rust_framework_chapters` exactly, wired
into `spec/corpus_rust_spec.rb`'s bucket formula (plus a new parallel assertion, "attaches
every vendored chapter through some Rust domain's hecksagon") and
`spec/codegen_parity_spec.rb`'s `CODEGEN_CORPUS_MEMBERS` derivation, both of which had
made the same "framework only" assumption for the same reason.

## A parallel gap in this repo's own test scaffolding: `Runtime::Registry.new` with no root

Three separate hand-rolled boot helpers — `bin/model_check`, `spec/model_check_spec.rb`,
and `spec/parser_parity_spec.rb` — each built a bare `Hecks::Runtime::Registry.new` with
no `root:` before loading a corpus member's bluebook/hecksagon. This is exactly what
`bin/project_rust`'s own generator script had to work around for the same reason (its own
comment: "a domain declaring `uses_embryonaut_bluebook`... refuses here with 'needs a
registry with a root to vendor from'") — `EmbryonautBluebook.load!` resolves
`<root>/vendor/embryonaut_bluebooks/<name>/bluebook/` off the registry's own root, which a
`uses_framework`-only corpus never needed. All three refused identically the moment they
tried to boot `examples/embryonaut_vendoring_demo` for real. Fixed the same way in all
three: `root: File.dirname(directory)` where `directory` is the domain's own `bluebook/`
folder — exactly `Runtime::Loader.boot`'s own relationship, harmless for every other
corpus member since none of them vendors anything.

## What was explicitly NOT touched

[0030](0030-rust-mints-its-own-eras-at-boot.md)'s Consequences section, and the fuller
scoping in [0030-vendored-lineage-scoping.md](0030-vendored-lineage-scoping.md), already
name a real, accepted, pre-existing gap: `rust/host`'s boot-time self-mint only
provisions head-snapshot tables for the TARGET domain's own aggregates
(`Exporter.lineage`'s `capable_aggregates`), never a `uses_framework`- or
`uses_embryonaut_bluebook`-attached chapter's own aggregates. Governance/Identity have
this gap in production today; `widgets` has it too, by the same mechanism, for the same
reason. This is not new, not introduced by this work, and not fixed here — a real
Postgres-backed deploy of `examples/embryonaut_vendoring_demo` (or any vendoring domain)
still needs `bin/project_deploy`'s generated `mint-era` Makefile step for the vendored
chapter's own aggregates, not automatic Rust-boot provisioning. Every fixture and spec
added by this work runs in-memory/dispatch conformance only, which this gap does not
affect — `Widget` is bound `persisted_by("Memory")` in the demo's own hecksagon, on
purpose, the same way Governance/Identity are bound `Memory` in `examples/banking`'s own
sibling hecksagon.

Also explicitly not attempted: reworking `reference_to` to cross chapter boundaries. This
session's own earlier finding — confirmed again here — is that `reference_to` is
same-chapter-scoped even across a framework/vendored attachment, so `Gadget` and `Widget`
coexist in the demo domain's merged dispatch table without referencing one another, the
same shallow, dispatch-table-only relationship Banking has with Governance/Identity.

## Living proof

- `examples/embryonaut_vendoring_demo/bluebook/{embryonaut_vendoring_demo.bluebook,embryonaut_vendoring_demo.hecksagon}`
  — the consuming domain.
- `examples/embryonaut_vendoring_demo/vendor/embryonaut_bluebooks/widgets/bluebook/widgets.bluebook`
  — the vendored package.
- `spec/corpus/embryonaut_vendoring_demo.json` — the plain corpus replay script every
  `:example` member needs (`spec/corpus_spec.rb`).
- `spec/corpus/rust_conformance/embryonaut_vendoring_demo_dispatch.json` — the byte-exact
  Ruby/Rust differential fixture (`spec/rust_conformance_spec.rb`), covering both aggregates
  and a refusal on each side.
- `spec/project_rust_pipeline_spec.rb`'s `PARITY_DOMAINS["examples/embryonaut_vendoring_demo"]`
  — the default-vs-opt-in-pipeline byte-exact proof.
- `rust/Cargo.toml`'s `embryonaut_vendoring_demo` feature; `rust/src/generated/{embryonaut_vendoring_demo,widgets}/`.

## Verification

All run for real, in this session, against a clean `cargo build` and this repo's real spec
runner (see this session's own final report for exact commands/output):

- `cargo test` (`rust/parser`): 37 + 11 tests, all passing, including the modified
  `hecksagon_fixtures_resolve_for_real` gate.
- `cargo build` (`rust/`, default features and `--features embryonaut_vendoring_demo`):
  clean, only pre-existing unused-import warnings shared with Governance/Identity's own
  generated code.
- `spec/rust_conformance_spec.rb`: 54 examples, 0 failures (includes
  `embryonaut_vendoring_demo_dispatch.json`).
- `spec/project_rust_pipeline_spec.rb`: 5 examples, 0 failures (includes
  `examples/embryonaut_vendoring_demo`).
- `spec/rust_conformance_fuzz_spec.rb`: 20 examples, 0 failures — every generated Rust
  domain in the repo, including `embryonaut_vendoring_demo`, agrees with Ruby across 5
  randomly generated sequences each.
- `spec/corpus_spec.rb`, `spec/corpus_accounting_spec.rb`, `spec/corpus_rust_spec.rb`,
  `spec/codegen_parity_spec.rb`, `spec/parser_parity_spec.rb`, `spec/parser_coverage_spec.rb`,
  `spec/word_coverage_spec.rb`, `spec/model_check_spec.rb`, `spec/dsl_coverage_spec.rb`,
  `spec/environment_overlay_spec.rb`, `spec/dsl_spec.rb`: 504 examples, 0 failures, 1
  pre-existing pending (BUG#32's `corrections` entry, unrelated).
- `bin/model_check` (whole corpus) and `bin/corpus --rust-coverage` (all 24 generated
  modules): clean, 0 errors/gaps.
