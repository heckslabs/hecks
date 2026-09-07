# Architecture map — what this system currently is

**This document answers "what," not "why."** The ADRs under `docs/decisions/`
and `docs/implemented/decisions/` answer "why," and they are a *decision log*,
not a system map — reading them as one produces a picture that is accurate about
every individual decision and wrong about the shape of the whole. This file
exists so nobody has to reconstruct the present from the history.

**Every number here was measured against the checkout, not estimated.** The
command that produces each is named beside it. Re-run them rather than trusting
the figure; if a number is stale, that is a bug in this file.

**What this replaces.** The previous version of this map was 51 lines and
contained the claim that `rust/src/kernel/{expr,dispatch}.rs` "is the one part
of this tree someone still writes by hand — everything else is projected." That
is wrong by a factor of roughly twenty (see *Handwritten vs generated*), and it
omitted `rust/host/` (11,081 lines) and `rust/lsp/` entirely.

---

## Two implementations, and where they meet

There is a Ruby implementation and a Rust implementation. Both can go from
`.bluebook` source to a running domain. They meet at **canonical IR**
(`ir.json`), which is the only interchange format either side needs.

```
.bluebook ──┬─ Ruby DSL builders ────┬─→ IR ──┬─ rust/project/*.rb  ─┬─→ generated Rust ─→ cargo ─→ binary / wasm
            │                        │        │                      │
            └─ rust/parser  ─────────┘        └─ rust/codegen/src   ──┘
               (hecks-parse)                     (hecks-codegen)
```

Each column has two implementations. **This duplication is the largest single
structural fact about the repo and is easy to miss** — it is what makes Rust a
peer rather than a downstream target.

| stage | Ruby | Rust |
|---|---|---|
| parse `.bluebook` → IR | `lib/hecks/bluebook/dsl/` (inside 16,262) | `rust/parser/src` — 12,193 |
| IR → Rust source | `rust/project/*.rb` — 7,362 | `rust/codegen/src` — 8,616 |
| run a domain | `lib/hecks/runtime/` — 8,646 | `rust/src/kernel/` — 9,396 |

`find <dir> -name '*.rb' -o -name '*.rs' | xargs cat | wc -l`

### Compiling without Ruby

```
HECKS_PARSER=rust HECKS_CODEGEN=rust bin/project_rust <domain>
```

Routes through `rust/project_rust_pipeline.rb` → `hecks-parse resolve`/`chapter`
→ `hecks-codegen full`, with **zero `Kernel.load` of any domain bluebook**. Both
env vars are required together, deliberately; either alone is a different and
unverified configuration. It is **opt-in, not the default** — the default body
of `bin/project_rust` is unchanged.

The Ruby that remains on that path is enumerated in
`rust/project_rust_pipeline.rb`'s own header and is not language work: a regex
read of a file's `Hecks.bluebook "Name"` header line, a `Dir.glob` for framework
members, and a sorted read of `GRAMMAR_FILES`. One known gap: `manifest.json`
(coverage bookkeeping only).

**Note the dependency this creates:** `codegen_parity_spec` and
`parser_parity_spec` prove the Rust path correct *by comparing it to Ruby*.
Ruby is the oracle. Retiring it removes the demonstration, not just an
implementation.

---

## Handwritten vs generated

| | lines | how measured |
|---|---|---|
| Ruby, all of `lib/` | 51,183 (328 files) | `find lib -name '*.rb' \| xargs cat \| wc -l` |
| Rust, handwritten | **44,367** | sum of the crates below, minus `rust/src/generated` |
| Rust, generated | **47,130** | `find rust/src/generated -name '*.rs' \| xargs cat \| wc -l` |

Handwritten Rust, by crate:

| crate | lines | what it is |
|---|---|---|
| `rust/parser/src` | 12,193 | `.bluebook` → IR. Partly generated (`keywords.rs`, `emit.rs`, `parse/mod.rs`); the per-construct `parse/*.rs` are handwritten |
| `rust/host/src` | 11,081 | the Lambda host — web, mint, journal, auth, IR-interpreting dispatch. **Never linked to the kernel crate** |
| `rust/src/kernel` | 9,396 | the generic interpreter every generated domain runs through |
| `rust/codegen/src` | 8,616 | IR → Rust source, the Rust port of `rust/project/*.rb` |
| `rust/src/exemplar` | 1,614 | reference shapes the generators are checked against |
| `rust/lsp` | 1,398 | editor language server |
| `rust/web/src` | 23 | wasm-bindgen `cdylib`; one export, `dispatch(&str) -> String` |

Two more directories under `rust/` carry no runtime code: `rust/build` (its own
crate — build tooling) and `rust/tests` (integration tests, e.g.
`from_json_round_trip.rs`). `rust/project` is Ruby, counted in the table above.

### What the generated 47,130 lines actually are

`rust/src/generated/*/[a-z]*.rs`, classified by enclosing function:

| function | lines | share |
|---|---|---|
| `from_json` | 9,424 | 20% |
| `to_json` | 5,344 | 11% |
| `field` | 5,030 | 11% |
| `dispatch_by_name` | 4,920 | 10% |
| `as_scalar` | 3,094 | 7% |
| `items` | 2,970 | 6% |
| `check_invariants` | 2,890 | 6% |
| `command_attributes_for_verb` | 1,251 | 3% |
| `extract_id`, `from_seed`, `instances`, `set_projected_field`, `find_fielded` | ~2,650 | 6% |

**JSON codec plus field reflection is 26,256 lines — 56% of everything
generated — and none of it is domain behavior.** It is generated rather than
derived because the kernel crate is deliberately std-only with zero Cargo
dependencies, so there is no serde. See `docs/behavior-projection-plan.md`
Track B.

---

## The Ruby library

```
lib/hecks/
  bluebook/            16,262   DSL → IR → expression. Reading a bluebook.
  runtime/              8,646   dispatch, instances, the registry. Running one.
  ports/                6,504   domain ports + their .port declarations
  adapters/             3,892   driven adapters + their .adapter declarations
  fuzzing/              3,858   generated sequences checked against declared properties
  forms/                1,751   IR → HTML, content-negotiated against JSON (prototype)
  projections/          1,470   IR as a capability — OIDC, reference, parser table
  projector/            1,379   IR serialization and projection targets
  facade/               1,107   the door — class-free, per boot
  query_specification/    757   a query's shape, held apart from any engine
  behaviors/              675   the .behaviors test DSL
  doc/                    416   the generated DSL reference (bin/reference)
  grammar/                348   expression/translation sublanguages + the Admit gate
  router/                 169   project-wide dispatch, namespace install at boot
  language/                 0   the language declared in its own bluebooks (no .rb)
  framework/                0   shared domain bluebooks — Identity, Governance, Compliance, ConsoleSettings
  deploy/                   0   the Deploy bluebook — what deployed_to must resolve to
```

`forms/` and `fuzzing/` stay out of the core boot chain; a project that never
uses one never pays for it.

### The dispatch pipeline

`CommandInterpreter::DISPATCH_ORDER` is read from the language, not hardcoded:
`Hecks::Vocabulary.symbols("AggregateDispatchOrder")` — 16 steps for aggregates,
15 for entities (`EntityDispatchOrder`), each dispatched as `step_<name>`. Rust
does **not** read this; `kernel/dispatch.rs` and `host/dispatch.rs` inline their
own ordering.

---

## The language describes itself

`lib/hecks/language/` declares the language in the language, judged by the same
`MetaValidator` that judges any domain:

- `bluebook/` — `syntax.bluebook` (how a bluebook is spelled), `vocabulary.bluebook`
  (the closed sets), plus a concept file per construct
- `hecksagon/`, `world/` — the wiring languages
- `port.bluebook`, `adapter.bluebook` — the sibling artifact languages
- `translation/` — the schema-evolution edge language
- `lib/hecks/grammar/` — `expression.bluebook` (the predicate sublanguage's
  admission ledger) and `translation.bluebook`

**Not self-hosted:** `.behaviors` (`Hecks.behaviors`), explicitly exempted in
`spec/syntax_conformance_spec.rb:149`.

Closed sets that exist in behavior with **no** declaration: read-model
aggregations (`group_by`/`count`/`median`) and null-ordering modes
(`native`/`first`/`last`).

---

## Ports and adapters

**Ports** (`lib/hecks/ports/*.port`): access_control, agent, authentication,
authorization, clock, extraction, identity_assignment, identity_generation,
identity_resolution, loading, persistence, projection.

**Driven adapters** (`lib/hecks/adapters/driven/*.adapter`): claude_code, d1,
folder, google_authentication, governance_authorization, heki,
identity_registry, lambda, local_storage, memory, mock_stripe, postgres,
postgres_era, prism, secure_random_identity, sqlite, system_clock.

An adapter's declared `field`/`secret` names are checked against a world's
wiring at `lib/hecks/runtime/registry/verification.rb:131`.

---

## What holds what — the gate matrix

This repo's defining habit: a declaration nothing reads cannot disagree with
anything, so nearly every table is held to its consumer **in both directions**.
279 spec files; 23 are conformance/parity/coverage gates.

| gate | holds |
|---|---|
| `syntax_conformance_spec` | `syntax.bluebook`'s rows ⇄ the live DSL builders |
| `vocabulary_conformance_spec` | every `Vocabulary` term ⇄ its runtime constant (incl. `DISPATCH_ORDER`) |
| `operator_conformance_spec` | the expression ledger ⇄ Ruby's `Evaluator`/`Resolver` tables |
| `query_comparator_conformance_spec` | `Vocabulary::QueryComparator` ⇄ Rust's hand-maintained enum, by reading the `.rs` source |
| `refusal_wording_conformance_spec` | `RefusalWording::TEMPLATES` ⇄ `Vocabulary::RefusalTemplate` |
| `kernel_capabilities_conformance_spec` | generated capability enums ⇄ the files that implement them |
| `parser_parity_spec` | `hecks-parse` output ⇄ Ruby's IR, byte-exact |
| `codegen_parity_spec` | `hecks-codegen` output ⇄ Ruby's generated Rust, byte-exact, whole-file on all six corpus members |
| `rust_conformance_spec` | the compiled binary ⇄ Ruby's replay, over a corpus |
| `dsl_coverage_spec` | every public builder method is accounted for |
| `guides_spec` / `bin/doc_coverage` | every live word has a running example |

Plus `bin/rust_kernel_coverage` (an admitted capability with no implementing
file fails the build) and `bin/check_engine_agreement` (Ruby's two query paths
must agree — it exists because they silently drifted twice).

**What no gate covers:** cases where both runtimes agree and are *identically*
wrong. That is `bin/model_check` and the fuzzer's declared properties, not a
parity harness.

---

## Deliberate asymmetries

Places the two runtimes differ on purpose. Each is handled, none is a bug.

- **Event timestamps.** Ruby sets `occurred_at` from `Time.now` inside the
  interpreter (`command_rules/emission.rb:23`); Rust's kernel "has no clock"
  (`kernel/cli.rs:386`) and takes it at the door. `bin/rust_conformance:119-129`
  strips the field before comparing.
- **Admitted subsets.** `rust/project/queries.rb`'s `query_skip_reason` and
  `read_models.rb`'s `read_model_skip_reason` mean a declared shape outside the
  supported subset gets **no generated row at all** and is refused cleanly —
  never silently wrong, but "parity" covers the subset, not everything.
- **Per-era modules.** `rust/web` notes "no per-era module selection, no
  host-adapter import boundary — those remain open."

---

## WASM

`bin/project_wasm <domain>` cross-compiles `rust/src/main.rs` **unchanged** for
`wasm32-wasip1` → `rust/dist/<domain>.wasm` plus an `ir.json` sidecar.
`bin/project_wasm_browser <domain>` builds `rust/web` → an ES module with
TypeScript definitions. `rust/host/src/wasm_runner.rs` runs those modules
through embedded wasmtime.

Both speak one contract: `{steps, seed?, sagas?}` in, `{instances, events,
refusals, queries}` out. `Store::instances`/`Store::from_seed` are mechanical
inverses, so state round-trips as JSON and persistence is the caller's business.
Ports take already-obtained facts as arguments — the module never calls out.

WASM is a **compile target of the Rust implementation**, not a third
implementation, and adds no drift surface.

---

## Not verified in this pass

Stated so the next reader knows where the map is thin rather than trusting it
uniformly:

- Per-file composition of `rust/host/src` beyond its top-level sizes.
- Whether `ir.json` is complete for every construct a dispatching runtime needs.
  One gap is known: **only value-object invariants carry an `ast:` key**
  (`lib/hecks/bluebook/value_object.rb:42`); command `given`/`ensures` and
  aggregate/entity invariants carry canonical *text* only.
- `rust/lsp` and `rust/build` internals.
- `editors/vscode` (the only other JS in the tree, `extension.js`).
