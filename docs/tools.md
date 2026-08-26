# The tools

Every script under `bin/` in one table — each summary is the tool's own
opening comment, truncated. Read the tool itself for the full
description, or run it with no arguments (most support `--help` or
print a usage line on a missing argument).

| tool | |
|---|---|
| `bin/backfill_era_projections` | Proactively backfills `hecks_eras.held_projection` for every row of one domain that predates that column — an explicit, operator-run vers... |
| `bin/behaviors` | Runs `.behaviors` files — hand-curated examples of how to use a domain, in domain vocabulary — and reports pass/fail/error per test. bin/... |
| `bin/canonicalise` | Sorts a JSON document's object keys, recursively — key order is not semantics, so a diff a human reads should not have to notice it moved. |
| `bin/codemod_hoist_local_givens` | A CODEMOD, not an agent — for the corpus duplication `bin/query_ir duplicates` surfaces directly: two or more commands under the SAME own... |
| `bin/codemod_implicit_append_fields` | A CODEMOD, not an agent — for the class of redundancy `CommandBuilder#resolve_append_fields!` (lib/hecks/bluebook/dsl/ command_builder.rb... |
| `bin/console` | Boots a domain (pizzas by default) and drops into IRB with its door installed — the fastest way to dispatch a real command by hand. bin/c... |
| `bin/doc_coverage` | EVERY LIVE WORD SHIPS WITH A RUNNING EXAMPLE, or this refuses. Prose is a declaration, and a declaration nothing runs cannot disagree wit... |
| `bin/docs` | A domain's usage document, projected from its own bluebook. bin/docs # list every domain in this checkout bin/docs examples/banking # the... |
| `bin/evolve` | The language-change convention, made executable. Adding a word to the bluebook surface has always been a many-file walk — syntax row, Rub... |
| `bin/expression_projection` | The expression machinery's tables, projected from the grammar chapter's admitted set and checked in, so the evaluator and the canonical f... |
| `bin/follow` | Live-tails a domain's own persisted event log — the declared `emits` every command reports, durably recorded (not `registry.event_log`, w... |
| `bin/fuzz` | Generates random-but-valid command/query sequences from a domain's own IR (Hecks::Fuzzing::SequenceGenerator) and checks each one the way... |
| `bin/generate` | Prints one randomly generated, valid dispatch sequence for a domain — the same generator bin/fuzz drives, exposed standalone so a sequenc... |
| `bin/hecks_mcp_door` | AN MCP DOOR ONTO THE STOREHOUSE BUS — one MCP server for EVERY booted domain, not one per command. `docs/hecks-survey-what-we-wish-we-had... |
| `bin/hecks_query_ir_mcp` | AN MCP SERVER exposing Hecks::QueryIR's two queries as tools, so a coding agent calls them directly instead of shelling out to `bin/query... |
| `bin/history` | Prints every journal entry a domain's append-only adapters hold, as JSON — the full write history, not just the current head. bin/history... |
| `bin/ir` | Prints a booted domain's IR as JSON — the same `to_h` the golden specs pin and StorageShape hashes into an era, for reading rather than a... |
| `bin/merge_tail` | Tail-merge: the one deliberate command. It marks a business event — an old app retiring — never a shape change. One transaction: advance ... |
| `bin/model_check` | STATIC ANALYSIS OVER THE IR — unreachable lifecycle states, transitions nothing can ever fire, saga states no handler chain reaches, a co... |
| `bin/narrate` | A domain, read back in English — projected from its own bluebook. bin/narrate # list every domain in this checkout bin/narrate examples/b... |
| `bin/pattern-cases` | THE RECORDED FIXTURE for `pattern:`, and how to regenerate it : bin/pattern-cases > spec/corpus/fixtures/patterns.json spec/pattern_subse... |
| `bin/present` | Boots the banking example against the in-memory adapter (same rebind spec/facade/handle_spec.rb already uses — banking.hecksagon itself b... |
| `bin/project` | Refreshes every read-model projection a domain declares, by hand — the same catch-up a boot runs lazily, forced now rather than on first ... |
| `bin/project_cli` | Mints a command-line binary for a domain, named after its bluebook. bin/project_cli # every domain in this checkout bin/project_cli qa # ... |
| `bin/project_deploy` | The AWS DEPLOYMENT projector — docs/decisions/0018-rehydrate-replay-lambda-host.md. Generates the SAM template and build Makefile for rus... |
| `bin/project_diagrams` | Projects a booted domain's own shape into Mermaid diagrams — one stateDiagram-v2 per lifecycle-bearing aggregate/entity, one erDiagram fo... |
| `bin/project_field_hints` | Generates rust/host/src/field_hints.rs — the four regex hints Hecks::Forms::FieldShape#text_field (lib/hecks/ forms/field_shape.rb) match... |
| `bin/project_kernel_capabilities` | Generates the two capability enums the hand-written Rust kernel (rust/src/kernel/attribute_shapes/*.rs, rust/src/kernel/ expression_opera... |
| `bin/project_model` | Projects the model's holding half from the language that declares it. Behaviour::X is hand-written and untouched; `settle` is the seam. b... |
| `bin/project_oidc` | Projects every domain's OIDC client/scope manifest into `<domain>/oidc.json` — the artifact half of §11, `Hecks::Projections::OIDC`, made... |
| `bin/project_parser_table` | Projects the chapter's own Syntax aggregate into the Rust parser's keyword table — the parser's grammar knowledge DERIVED from hecks's se... |
| `bin/project_refusal_wording` | Generates rust/src/kernel/refusal_wording.rs from `Hecks::Runtime:: RefusalWording::TEMPLATES` (lib/hecks/runtime/refusal_wording.rb) — t... |
| `bin/project_rust` | Generates Rust source for one domain into rust/src/generated/ — the driver for `RustProjection` (rust/project.rb, alongside the Rust crat... |
| `bin/project_tenant` | THE TENANT PROVISIONER — same split bin/project_deploy already draws between VALIDATING a declared shape (lib/hecks/deploy's own Tenant.D... |
| `bin/project_vocabulary` | Projects the language's own closed sets into lib/hecks/vocabulary.rb. A one-line wrapper over the projector registry, deliberately — the ... |
| `bin/project_wasm` | The WASM projector — wraps THE SAME Rust binary bin/project_rust already generates, rather than a second, WASM-specific implementation (d... |
| `bin/project_wasm_browser` | The BROWSER wasm-bindgen projector — decision docs/decisions/0015-wasm-bindgen-browser-projection.md. Deliberately a SEPARATE binary from... |
| `bin/query_ir` | STRUCTURED QUERIES AGAINST THE LANGUAGE'S OWN IR — for a session working ON the language (adding a resolution rule, checking a propagatio... |
| `bin/reattest_era` | The recovery path after a held-text integrity refusal. The digest is tamper-EVIDENCE — it catches accident and drift, not an adversary (a... |
| `bin/reference` | Regenerates docs/implemented/reference/ from the language's own Syntax chapter — the tables from the declaration, the prose preserved fro... |
| `bin/run` | Executes a step list — commands and queries, declared as JSON — and reports instances, events, refusals, reactions, sagas, and query rows... |
| `bin/rust_conformance` | THE DIFFERENTIAL HARNESS — docs/decisions/0010-ruby-is-the-reference-implementation.md. Ruby is the oracle a second runtime is checked ag... |
| `bin/rust_coverage` | THE COVERAGE CHECKER — a different question than bin/rust_conformance asks, deliberately, not a replacement for it. bin/rust_conformance ... |
| `bin/rust_kernel_coverage` | THE MECHANICAL, COMMENT-TAG-FREE HALF OF THE GUARANTEE. bin/project_kernel_capabilities generates the ENUM half — the compiler already re... |
| `bin/scaffold_translation` | The scaffold writes translations; humans resolve ambiguity. Diffs the held era against the current bluebook and writes the edge file: con... |
| `bin/shape` | The storage-shape projection of one bluebook file, as JSON — the exact form StorageShape.mint_hash hashes to name an era, printed so a bu... |
| `bin/smoke_test` | BOOTS A REAL DOMAIN AND ACTUALLY DISPATCHES AGAINST IT — the sibling `bin/model_check` never had. That tool proves a bluebook is STRUCTUR... |
| `bin/statements` | Prints a booted domain's own declared facts as plain English sentences — the projection itself is Projections::Statements (see its own he... |
| `bin/stores` | Prints every aggregate's current records, as JSON — the head, not the journal (bin/history prints the full write history instead). bin/st... |
| `bin/translation_audit` | The audit derives its assertions. Layer 1: every translated state passes the new era's types, invariants, and lifecycle. Layer 2: the com... |
