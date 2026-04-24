---
title: "Hecks: A Five-DSL Domain Compiler with Contract-Driven Multi-Target Generation and Futamura-Style Self-Hosting"
authors: "Chris Young, with contributions from <placeholder>"
version: "paper/hecks-v0-2026-04-24"
commit: "c4a903f3"
date: 2026-04-24
---

# Hecks: A Five-DSL Domain Compiler with Contract-Driven Multi-Target Generation and Futamura-Style Self-Hosting

**Version:** `paper/hecks-v0-2026-04-24`
**Repository commit at time of writing:** current HEAD of `main` (post Phase E close-out, 2026-04-24)
**Authors:** Chris Young, with contributions from *(placeholder — author list to be filled in by Chris Young prior to deposit).*

## Abstract

Hecks is an open-source domain compiler that treats a software domain as a first-class artifact described by five Domain-Specific Languages (DSLs): `.bluebook` for the domain model, `.hecksagon` for hexagonal ports and adapters, `.fixtures` for seed data and catalog schemas, `.behaviors` for behavioural tests, and `.world` for runtime and extension configuration. The runtime is a Rust binary (`hecks_life/`) — formerly one of two peer runtimes, now the sole one after the i51 arc (below); a Ruby gem (`lib/hecks/`) survives as host-language binding for Rails integration. During the years when Ruby and Rust were maintained as peer runtimes, a hand-written canonical Intermediate Representation (IR) and a multi-thousand-fixture parser parity corpus kept them byte-identical — that parity work is what made cross-language migration tractable (§13.5.1). Hecks ships sixteen data contracts (`lib/hecks/conventions/`) that drive multi-target code generation to Go, Node/TypeScript, and a zero-dependency Ruby static target. The framework also describes itself: chapter bluebooks enumerate every Ruby class in `lib/`, a coverage verifier asserts they match, and a parity verifier confirms the Ruby and Rust interpreters agree on aggregate and command counts per chapter. Two self-hosting arcs are reported. First, `hecks compile` produces a single-file zero-dependency Ruby binary of the framework by composing an Abstract Syntax Tree (AST) analysis with a Bluebook-IR method-call graph — an instance of Futamura's first projection (Futamura, 1971) applied to the Ruby interpreter. Second, the i51 arc applies partial evaluation to the Rust runtime through five shipped phases (A–E): every Rust module under `hecks_life/src/` regenerates byte-identical from a shape bluebook lowered through an L0–L8 IR factoring; the meta-specializer regenerates its own source byte-identical (Phase C PC-4 fixed point); Phase D ported the specializer itself from Ruby to Rust, byte-identically; Phase E deleted the Ruby specializer orbit. The runtime has collapsed from two peers into one (Rust) plus a host-language binding (Ruby gem). We enumerate twenty-plus techniques with direct file references as the defensive-publication payload. The paper's claims are reproducible from the public repository at the tag above.

---

## §1 Introduction

Enterprise software developers work under two mutually reinforcing pressures. First, business requirements are captured in a spoken or written ubiquitous language (Evans, 2003) which must then be translated — typically by hand, typically many times — into code spanning multiple runtimes (application server, background worker, browser client, migration tool, test harness). Second, the cost of disagreement between these runtimes is paid repeatedly: an event emitted in Ruby and consumed in Go must have the same JSON shape; a validation rule enforced in the back-end must match the HTML form on the front-end; a migration rolled out of the application must be round-trippable through the snapshot diffing tool. In practice this agreement is maintained by convention, test suites, and the occasional Slack thread.

Hecks addresses both pressures by collapsing the distinction between "the model" and "the code": a domain is declared once in a family of five DSLs; every runtime, generator, and verifier then reads from the same parsed Intermediate Representation (IR). Agreement between runtimes is no longer a matter of discipline but a property enforced by a parser-parity test suite and sixteen data contracts that each code generator must consume.

The paper has two audiences. For the enterprise developer, we describe the DSL vocabulary, the hexagonal-adapter declaration mechanism, and the behavioural-test cascade lockdown with the intent that they be immediately recognisable and adoptable. For the programming-language and compiler-research audience, we describe the framework's self-hosting properties — particularly the factoring of the Rust interpreter into eight IR layers (L0–L8) and the module-by-module retirement of hand-written Rust via partial evaluation. The i51 arc has since completed: every Rust module under `hecks_life/src/` regenerates byte-identical from a shape, the meta-specializer holds byte-identity against its own source (Phase C PC-4 — the second Futamura fixed point proved at the per-file level), and what had been the Ruby `bin/specialize` driver is now `hecks-life specialize <target>` — a Rust subcommand. §9 gives the formal treatment.

We publish this as a defensive-publication document so the techniques described here, whether or not they are pursued commercially elsewhere, remain available as prior art.

### §1.1 Contribution

The contributions are:

1. A five-DSL vocabulary for declaring a domain, its adapters, its seed data, its tests, and its runtime configuration. A repository-wide "antibody" enforcement mechanism prevents a sixth DSL extension from entering the codebase.
2. A canonical JSON IR with hand-written dumpers in two languages and a 920-fixture parity test suite.
3. Sixteen data contracts (`lib/hecks/conventions/`) that drive code generation to three targets (Go, Node/TypeScript, static Ruby).
4. A hexagonal-adapter DSL in which `:memory`, `:sqlite`, `:heki`, `:stdin`, `:stdout`, `:stderr`, `:fs`, `:env`, and `:shell` adapters are declared as data; the `:shell` adapter carries a declared security contract implemented identically in Ruby and Rust.
5. A behavioural-test DSL with cascade lockdown — `expect emits: [...]` asserts the exact ordered event list produced by a command, including all downstream policy cascades.
6. A framework-as-chapters construction in which `hecks/*.bluebook` enumerates every Ruby class in `lib/`; a coverage verifier walks `lib/` and checks each `.rb` file's basename matches a chapter aggregate; a parity verifier invokes the Rust binary and compares counts.
7. A Ruby binary compiler (`hecks compile`) producing single-file zero-dependency output via a two-layer dependency graph (Prism AST + Bluebook-IR method-call resolution).
8. A completed module-by-module Futamura specialisation of the Rust runtime, proven at two fixed points: (a) every generated `.rs` target regenerates byte-identical from a shape, and (b) the meta-specializer that regenerates the specializer's own source also holds byte-identity (Phase C PC-4). Phase D migrated the specializer from Ruby to Rust, preserving byte-identity across interpreters; Phase E deleted the Ruby-side framework machinery. The runtime has collapsed into one language plus a Ruby gem binding for host-language integration.

### §1.2 Paper organisation

§2 enumerates the five DSLs. §3 describes the IR and parity corpus. §4 describes contract-driven multi-target generation. §5 describes hexagonal adapter declaration. §6 describes the behavioural-test DSL. §7 describes chapter self-hosting. §8 describes the shipped autophagy path. §9 gives the formal treatment of Futamura projections across the Rust runtime. §10 evaluates; §11 is related work; §12 is the enumerated defensive-publication payload; §13–15 close. Three appendices give an end-to-end example, a contract table, and abridged grammars.

---

## §2 The Five-DSL Vocabulary

Hecks expresses a domain through five file extensions. Each extension has an authoritative parser in both Ruby and Rust, and an authoritative builder (the Ruby Internal DSL form). Table 2.1 summarises.

**Table 2.1 — The five DSL file extensions.**

| Extension    | Purpose                                                                 | Rust IR parser                    | Ruby builder                          |
|--------------|-------------------------------------------------------------------------|-----------------------------------|---------------------------------------|
| `.bluebook`  | Domain model: aggregates, commands, events, policies, lifecycles, value-objects, references, queries, mutations, givens, invariants | `hecks_life/src/ir.rs`, `parser.rs` | `lib/hecks/dsl/` via `Hecks.bluebook` |
| `.hecksagon` | Port/adapter wiring: `adapter`, `gate`, `subscribe`                     | `hecks_life/src/hecksagon_ir.rs`, `hecksagon_parser.rs` | `lib/hecksagon/dsl/` via `Hecks.hecksagon` |
| `.fixtures`  | Seed rows and catalog schemas, sibling to a `.bluebook`                 | `hecks_life/src/fixtures_ir.rs`, `fixtures_parser.rs`  | `Hecks.fixtures`                      |
| `.behaviors` | Behavioural tests: `tests { setup / input / expect }`                   | `hecks_life/src/behaviors_ir.rs`, `behaviors_parser.rs` | `Hecks.behaviors`                     |
| `.world`     | Runtime and extension configuration                                     | `hecks_life/src/world_ir.rs`       | `lib/hecksagon/dsl/world_builder.rb`  |

A minimal `.bluebook` declares aggregates with commands, value-objects, queries, and optional lifecycle transitions:

```ruby
Hecks.bluebook "Pizzas" do
  vision "Manage pizza creation, customization, and ordering"
  core

  aggregate "Pizza" do
    attribute :name
    attribute :description
    attribute :toppings, Topping
    value_object "Topping" do
      attribute :name
      attribute :amount, Integer
      invariant "amount must be positive" do
        amount > 0
      end
    end
    command "CreatePizza" do
      role "Chef"
      goal "Add a new pizza to the menu"
      attribute :name
      attribute :description
    end
  end
end
```

### §2.1 Antibody enforcement

The five extensions are the full vocabulary. A repository-level mechanism, colloquially called the *antibody*, prevents a sixth DSL extension from entering the codebase by accident. It consists of:

- `bin/antibody-check` — a scanner that walks the repository for file extensions outside the allowed set.
- `bin/git-hooks/commit-msg` — a blocking pre-commit gate (Gate B) that rejects commits introducing new extensions.
- `bin/git-hooks/pre-commit` — an informational gate (Gate 5) that warns earlier in the commit flow.
- `.github/workflows/antibody.yml` — a GitHub Actions workflow that runs the same scanner on every push.

A single-commit escape hatch is provided via an `[antibody-exempt: <reason>]` marker on its own line in the commit message. Exemptions are examined by a human reviewer.

### §2.2 Corpus size at time of writing

The repository currently holds 920 `.bluebook` files (the majority in `hecks_conception/nursery/` — 352 bounded-context prototypes), 17 `.hecksagon` files, 7 `.world` files, 463 `.behaviors` files, and 339 `.fixtures` files. These are the numbers counted for this paper; they grow daily.

---

## §3 IR and Parser Parity

The five DSLs share a common concern: a domain written in the DSL must mean the same thing in every runtime that reads it. Hecks enforces this by defining a *canonical JSON IR* — a normalised representation of each DSL — and by maintaining hand-written dumpers in Ruby and Rust that produce the same canonical JSON for the same input.

### §3.1 Canonical IR shape

The Bluebook canonical JSON has the shape:

```json
{
  "name": "Pizzas",
  "category": null,
  "vision": "Manage pizza creation, customization, and ordering",
  "aggregates": [
    {
      "name": "Pizza",
      "attributes": [...],
      "commands": [...],
      "value_objects": [...],
      "queries": [...],
      "references": [...],
      "lifecycle": null
    }
  ],
  "policies": [],
  "fixtures": []
}
```

The canonicalizer in Rust is `hecks_life/src/dump.rs` (180 lines of code, hand-written). The canonicalizer in Ruby is `spec/parity/canonical_ir.rb` (hand-written). Both emit keys in the same order, normalise nullables the same way, and stringify types the same way. Parity is defined as byte-equal output from the two canonicalizers for the same input file.

### §3.2 Parity corpus

The parity test lives at `spec/parity/parity_test.rb`. It walks a corpus of bluebook fixtures, runs each through both parsers, canonicalizes, and diffs.

The corpus is partitioned into *hard* sections (must always pass) and *soft* sections (may drift). The hard sections at time of writing are:

- 14 synthetic fixtures (`spec/parity/bluebooks/01_minimal.bluebook` through `17_legacy_top_level.bluebook`) exercising edge cases.
- 41 real aggregate bluebooks from `hecks_conception/aggregates/`.
- 35 capability bluebooks from `hecks_conception/capabilities/`.
- 20 catalog bluebooks.
- 19 miscellaneous.
- Total hard: **129/129** pass.

The soft section is the nursery — 368/375 currently pass; the seven failures are blocked on inbox items i1 and i2 (a Ruby parser bug with certain Symbol-to-Float and Symbol-to-Integer conversions). Soft failures are tracked by exact fixture path in `spec/parity/known_drift.txt`, which is currently empty (full hard parity is the today baseline; the seven soft nursery items are outside `known_drift.txt` because they are counted in the overall soft total of 368/375).

### §3.3 Status legend and celebrate-and-remove

The test produces four statuses per fixture:

- `✓` pass.
- `✗` unexpected drift. Exit 1.
- `⚠` expected drift (listed in `known_drift.txt`).
- `⚑` a listed drift that has started passing. Not a failure — the suite asks the developer to delete the entry to prevent bit-rot.

The `⚑` semantics is what we call *celebrate-and-remove*: resolved known-drift entries are surfaced to a human rather than silently auto-removed. This keeps the known-drift list honest — an entry in `known_drift.txt` must describe a real, current, reproducible gap.

### §3.4 Parity across all five DSLs

Parity is not only for `.bluebook`. The `spec/parity/` directory also holds:

- `hecksagon_parity_test.rb`
- `fixtures_parity_test.rb`
- `behaviors_parity_test.rb`
- `world_parity_test.rb`
- `fuzz/` — property-based fuzzing tests

All five parsers have both Ruby and Rust implementations, and all five are subject to the same hard/soft corpus discipline. A pre-commit hook (`bin/git-hooks/pre-commit`) runs the suite in approximately one second; a CI workflow `.github/workflows/parity.yml` runs on every PR.

---

## §4 Contract-Driven Multi-Target Generation

Hecks generates runnable code for three targets from the same parsed IR: Go, Node/TypeScript, and a zero-dependency static Ruby target. Cross-target consistency is achieved by routing every code-generation decision through a sixteen-file *contracts* directory, `lib/hecks/conventions/`. A contract is a pure-data module that answers questions like "given an Attribute with a Ruby type of Integer, what is the Go type, the SQL column type, the JSON Schema type, the TypeScript type, and the coerce expression in Ruby?"

### §4.1 The sixteen contracts

Contracts live as siblings in `lib/hecks/conventions/`. Table 4.1 lists them.

**Table 4.1 — The sixteen contracts.**

| Contract              | LoC | Purpose                                                                                 |
|-----------------------|-----|-----------------------------------------------------------------------------------------|
| `AggregateContract`   | 169 | Field classification, validations, enums, self-ref detection, create/update partitioning |
| `CommandContract`     | 73  | Command method-name derivation, aggregate-suffix matching                              |
| `CsrfContract`        | 43  | CSRF token handling for generated forms                                                 |
| `DispatchContract`    | 62  | Command-bus dispatch routing                                                            |
| `DisplayContract`     | 192 | Cell expressions, lifecycle labels, reference display fields                            |
| `EventContract`       | 45  | Event interface, required fields (`aggregate_id`, `occurred_at`)                        |
| `EventLogContract`    | 55  | JSON shape for `GET /_events` (identical Ruby/Go)                                       |
| `ExtensionContract`   | 131 | Extension kind classification and boot order                                            |
| `FormParsingContract` | 77  | Go type → HTML input spec, Go parse lines, Ruby coerce expressions                      |
| `MigrationContract`   | 83  | Round-trip serialisation for domain snapshots                                           |
| `NamingContract`      | 125 | Naming convention enforcement                                                           |
| `NamingHelpers` (mixin) | 88 | Singularize/pluralize/humanize helpers                                                  |
| `RouteContract`       | 25  | URL patterns (`form_path`, `submit_path`) for command routes                            |
| `TypeContract`        | 115 | Single type registry (Go, SQL, JSON, OpenAPI, TypeScript) + `format_go_literal`         |
| `UILabelContract`     | 49  | PascalCase splitting, ActiveSupport pluralization, strips `_id` suffix                  |
| `ViewContract`        | 251 | Template data shapes (layout, home, index, show, form, config), Go struct generation    |

Total: 1,583 lines. Every generator consumes at least one contract; most consume three or four. A single change to (say) how `Integer` maps to Go therefore propagates to the Go server generator, the static Ruby renderer, and the TypeScript type emitter without any generator-to-generator coordination.

### §4.2 Generators

The generators directories are:

- `lib/go_hecks/generators/` — aggregate, application, command, errors, event, form template, index template, lifecycle, memory adapter, multi-project, multi-server, policy, port, project, query, register, registry, renderer, runtime, and server generators.
- `lib/node_hecks/generators/` — TypeScript target.
- `lib/hecks_static/generators/` and `lib/hecks_static/templates/` — zero-dependency static Ruby target.

Each generator is an Object that takes a parsed IR, consults contracts, and writes files. There is no generator-to-generator communication; each is a pure function of IR plus contracts.

### §4.3 ERB-as-source-of-truth with build-time Go transpilation

Multi-target HTML generation presents a known difficulty: Ruby ERB and Go's `html/template` are syntactically and semantically distinct. Hecks resolves this by making ERB the single source of truth and transpiling ERB directives to Go template directives at build time. A `<%= domain_form.render %>` in an ERB template is translated, by the Go generator, into the equivalent `{{.Form.Render}}` in the emitted `.tmpl` file. This means templates are authored once; the Go binary is produced from the same files.

---

## §5 Hexagonal Adapters as Declared Infrastructure

A `.hecksagon` file declares the ports and adapters for a domain, adopting Cockburn's *Hexagonal Architecture* / *Ports and Adapters* pattern (Cockburn, 2005) as first-class syntax. The DSL's name is a direct homage: `.hecksagon` is the hexagon. Adapters are not imported as libraries; they are *named and configured* in a DSL that Ruby and Rust runtimes both parse.

### §5.1 Adapter vocabulary

The primary adapter kinds are: `:memory`, `:sqlite`, `:heki` (a Hecks-native append-only store), `:stdin`, `:stdout`, `:stderr`, `:fs`, `:env`, and `:shell`. A minimal Pizzas `.hecksagon` is:

```ruby
Hecks.hecksagon "Pizzas" do
  capabilities :crud
end
```

A more involved example from the Futamura work wires three adapter categories to a single capability:

```ruby
Hecks.hecksagon "Specializer" do
  adapter :memory
  adapter :fs, root: "."
  adapter :shell,
    name:    :specialize_validator,
    command: "bin/specialize-validator",
    args:    ["--output", "{{output}}"],
    ok_exit: 0
  gate "SpecializeRun", :autophagy do
    allow :Specialize
  end
end
```

### §5.2 Shell adapter security contract

The `:shell` adapter is the largest security surface in any framework that shells out, so Hecks bakes a contract into both its dispatchers. The Ruby dispatcher is `lib/hecks/runtime/shell_dispatcher.rb` (163 LoC); the Rust dispatcher is `hecks_life/src/runtime/shell_dispatcher.rs` (190 LoC). Both implement the same security contract:

1. **No shell interpretation.** Execution goes through `Open3.capture3`/`Open3.popen3` in Ruby and `std::process::Command` in Rust, never through `sh -c` or its equivalents. Meta-characters in arguments are never interpreted.
2. **Env-clear baseline.** The child inherits the empty environment (`unsetenv_others: true` in Ruby; explicit `env_clear` in Rust). Only entries declared on the adapter cross.
3. **Explicit `working_dir`.** The caller cannot rely on the parent's cwd.
4. **Sealed empty stdin.** No piping into the child process in v1.
5. **Active-kill on timeout.** On timeout the dispatcher sends `SIGKILL` to the process group, not only the child PID, preventing orphaned descendants.
6. **Per-argument placeholder substitution.** `{{name}}` tokens are resolved per argument vector element. There is no string interpolation form; the argument list is always an array of strings.

Output formats are `:text`, `:lines`, `:json`, `:json_lines`, `:exit_code`. A successful call returns `Result(output, raw_stdout, stderr, exit_status)`.

### §5.3 Dispatchability

Shell adapters are dispatched via `runtime.shell(:name, **attrs)` and are subject to the same gates and middleware as any other command. This means the codegen steps of §9 are addressable as domain commands, not as build scripts — a distinction we return to when discussing the specialiser.

---

## §6 Behavioural Tests with Cascade Lockdown

Hecks adds a dedicated `.behaviors` DSL for asserting the observable event output of a command, including all downstream policy cascades. The DSL is small:

```ruby
Hecks.behaviors "Pizzas" do
  tests "CreatePizza emits one event" do
    setup {}
    input  CreatePizza: { name: "Margherita", description: "Classic" }
    expect emits: [:CreatedPizza]
  end
end
```

### §6.1 Auto-generation

A `conceive-behaviors` CLI subcommand walks any source bluebook's IR and emits a `_behavioral_tests.bluebook` with one test per command, query, lifecycle transition, and `given` clause. This produces a baseline suite that can then be trimmed or extended manually. The auto-generated tests include cross-aggregate cascade setups — the generator walks `aggregates_touched_by_cascade` and emits `Create` setups for every aggregate the cascade hops through.

### §6.2 Cascade lockdown

The distinctive property of the `.behaviors` DSL is *cascade lockdown*. A command rarely emits only one event; policies subscribe to its events, trigger follow-up commands, and those commands emit further events. The `expect emits: [...]` clause locks down the exact ordered list. If a developer adds a policy that changes the emission order or inserts a new event, every behavioural test that exercises that cascade will fail at once and point to the change.

Prediction of the emission list is done by a cascade walker at `hecks_life/src/cascade.rs`. It walks `emit → policy → trigger` edges, mirroring the runtime `PolicyEngine` cycle detection: a policy is blocked while on the recursion stack, allowing diamond fan-in patterns without infinite recursion.

### §6.3 Two dispatch modes

The behavioural-test runner supports two dispatch modes:

- `dispatch` — cascades policies. Used by `kind: :cascade` tests.
- `dispatch_isolated` — skips policy drain. Used by test setup phases so setup does not entangle with the command under test.

Both modes share the same command-bus implementation; only the policy-drain phase differs.

---

## §7 Chapter Self-Hosting

Hecks describes itself using its own DSLs. The directory `hecks/` contains twelve *chapter bluebooks* in scope for this paper, one per functional area of the core framework: `appeal.bluebook`, `bluebook.bluebook`, `cli.bluebook`, `extensions.bluebook`, `hecksagon.bluebook`, `packaging.bluebook`, `persist.bluebook`, `runtime.bluebook`, `spec.bluebook`, `targets.bluebook`, `templating.bluebook`, and `workshop.bluebook`. A thirteenth seed bluebook, `binding.bluebook`, lives in `hecks_genetics/`.

### §7.1 Aggregate counts per chapter

Each chapter bluebook declares one aggregate per Ruby class in its corresponding `lib/` subtree. The count distribution is:

**Table 7.1 — Aggregates per chapter bluebook.**

| Chapter       | Aggregates |
|---------------|------------|
| bluebook      | 233        |
| runtime       | 110        |
| cli           | 74         |
| targets       | 53         |
| extensions    | 47         |
| workshop      | 37         |
| hecksagon     | 34         |
| appeal        | 34         |
| spec          | 12         |
| templating    | 11         |
| persist       | 8          |
| packaging     | 3          |

`bluebook.bluebook` alone declares 233 aggregates — one per Ruby class in the `bluebook/` subtree, including `Domain`, `Aggregate`, `Attribute`, `Command`, `BluebookBuilder`, `AggregateBuilder`, `InMemoryLoader`, `DependencyGraph`, and `SourceAnalyzer`.

### §7.2 The six-phase verifier

`lib/hecks/chapters/verify.rb` orchestrates six verification phases:

1. **Chapter.** Every chapter description is non-empty.
2. **Contracts.** Every contract in `lib/hecks/conventions/` has a matching aggregate.
3. **Runtime.** Each chapter boots, executes, and round-trips through its own IR.
4. **Generators.** Every generator produces output for each chapter's IR.
5. **Coverage.** Every `.rb` file in `lib/` matches a chapter aggregate by name.
6. **Parity.** Ruby and Rust agree on aggregate and command counts per chapter.

### §7.3 Coverage verification

`lib/hecks/chapters/verify_coverage.rb` contains `CoverageVerifier`. It walks `lib/` and checks that each `.rb` file's basename matches a chapter aggregate name in either PascalCase or underscore form. Files without a matching aggregate are reported as warnings; the user is expected to either add the aggregate to a chapter or remove the file.

### §7.4 Parity verification

`lib/hecks/chapters/verify_parity.rb` contains `ParityVerifier`. For each chapter bluebook it invokes `hecks_life/target/debug/hecks-life counts <path>` (the Rust binary's `counts` subcommand) and compares aggregate and command totals against the Ruby parser's output. A mismatch fails the phase.

### §7.5 In-memory domain loading

`lib/hecks/bluebook/in_memory_loader.rb` implements a facility central to the chapter verifier: it takes a parsed Bluebook Domain IR, generates Ruby source code that would produce it if run, and `eval`s that source. No disk access is required. This is used, among other places, by the chapter runtime phase to boot a domain from IR without writing temporary files.

---

## §8 Autophagy: Binary Compilation of Hecks Itself

Hecks compiles itself to a single-file, zero-dependency Ruby binary via the `hecks compile` command. The binary responds to `boot`, `version`, and `self-test` subcommands. This section describes the implementation and frames it as an instance of Futamura's first projection (formal treatment in §9).

### §8.1 CLI

```sh
$ hecks compile              # → ./hecks_v0
$ hecks compile --plan       # show load order, exit
$ hecks compile --output NAME
$ hecks compile --trace      # narrate every step
```

### §8.2 Implementation

The compiler is `lib/hecks/compiler/` — ten files, 1,197 LoC total:

**Table 8.1 — The binary compiler.**

| File                       | LoC | Role                                                                       |
|----------------------------|-----|----------------------------------------------------------------------------|
| `binary_compiler.rb`       | 56  | Orchestrator.                                                              |
| `source_analyzer.rb`       | 206 | Two-layer dependency resolution.                                           |
| `definition_extractor.rb`  | 115 | Prism AST walker for constant definitions.                                 |
| `reference_extractor.rb`   | 155 | Prism AST walker for constant/method/mixin references.                     |
| `dependency_graph.rb`      | 141 | Graph assembly + topological sort.                                         |
| `cycle_sorter.rb`          | 76  | Greedy topo sort within Strongly Connected Components (SCCs).              |
| `constant_resolver.rb`     | 99  | Namespace-aware constant resolution.                                       |
| `source_transformer.rb`    | 113 | Strips `require`; expands compact class syntax `class A::B::C` to nested. |
| `forward_declarations.rb`  | 61  | Emits empty module shells so references resolve before definitions.        |
| `bundle_writer.rb`         | 129 | Concatenates files in load order; emits shebang + CLI dispatcher.          |

### §8.3 The two-layer dependency graph

A single-layer AST-based dependency graph is insufficient because Hecks makes heavy use of framework-level registration methods such as `Hecks.describe_extension`. A file that calls `Hecks.describe_extension` depends on the registry file that defines that method — but the AST alone has no way to know which registry file that is.

`source_analyzer.rb` therefore builds two layers:

1. **Layer 1 — Prism AST.** Prism is Ruby's standard AST library since Ruby 3.3. The analyser walks every `.rb` file and records constant references, inheritance (`class X < Y`), `include M` mixins, `extend`, and `prepend`.
2. **Layer 2 — Bluebook-IR method-call resolution.** The analyser builds an index of `Hecks.<method>` calls → the registry file under `lib/**/registries/` that defines `<method>`. Method-call edges are added to the graph. Example: a file calling `Hecks.describe_extension` gains an edge to `lib/hecks/registries/extension_registry.rb`.

The resulting graph is topologically sorted. Strongly connected components are broken by a greedy in-SCC sort; forward module shells are emitted for constants referenced before their definition.

### §8.4 Priority-ordered load and exclusions

A small priority list loads first: `errors.rb`, `conventions/`, `autoloads.rb`, `version.rb`, `registry.rb`, `registries/`, `naming_helpers.rb`, `hecks/generator.rb`, `hecks/dry_run_result.rb`. Everything else follows the topological order.

A wiring file is a `foo.rb` such that `foo/` is a directory AND `foo.rb` contains `extend`, `include`, or `prepend`. Wiring files load after their children.

Excluded directories: `/templates/`, `/spec/`, `/examples/`, `/compiler/`, `/hecks_cli/`, `/hecks_serve/`, `/hecks_mongodb/`, `/hecks_ai/` (external-dependency or build-tool code not required by the core runtime).

The bundle writer pre-registers every file path in `$LOADED_FEATURES` to prevent double-loading if an upstream file re-enters via `require`.

### §8.5 Framing: first Futamura projection applied to the Ruby interpreter

The Ruby interpreter is a program that takes source code and input and produces output: `I(P, D) = I(Hecks, D)`. Specialising the interpreter on `P = Hecks` produces a program whose sole input is `D` — a standalone binary. `hecks compile` is such a specialiser, implemented as a dependency-graph-aware Ruby bundler. This is Futamura's first projection in the specific form `mix(Ruby, Hecks) = hecks_v0`. §9 develops this machinery more carefully in the Rust context.

---

## §9 Futamura Across the Rust Runtime (i51) — Formal

This section is the paper's one formal section. Everything before and after is prose with code references.

### §9.1 Notation

Let $I$ be an interpreter: a program that takes source $P$ and input $D$ and returns $I(P, D)$. Let $\mathtt{mix}$ be a *partial evaluator* (also *specialiser*): a program that takes another program and some of its inputs, and returns a specialised version with those inputs statically baked in. We write $\mathtt{mix}(F, X)$ for the residual program that, given the rest of $F$'s inputs, computes what $F$ would have computed given $X$ and those inputs.

### §9.2 The three Futamura projections

Following Futamura (1971) and the standard restatement in Jones, Gomard, and Sestoft (1993):

- **First projection.** $\mathtt{mix}(I, P) = P'$. Specialising an interpreter on a source program yields a compiled form of that program.
- **Second projection.** $\mathtt{mix}(\mathtt{mix}, I) = \mathtt{compiler}$. Specialising the partial evaluator on an interpreter yields a compiler for the interpreter's language.
- **Third projection.** $\mathtt{mix}(\mathtt{mix}, \mathtt{mix}) = \mathtt{compiler\_generator}$. Specialising the partial evaluator on itself yields a compiler-generator: given any interpreter as input, it returns a compiler for that interpreter's language.

Hecks's §8 binary compiler is an instance of the first projection applied to the Ruby interpreter (CRuby with the Hecks library loaded as $P$). The work described in the remainder of this section is the in-progress arc "i51", applying the first projection to the Rust runtime module by module, with the second projection as its declared Phase C.

### §9.3 The L0–L8 factoring

The Rust interpreter's internal stages are named and promoted to first-class IR layers. Each layer is a pure function of the layer above. Composition across all nine layers is the interpreter.

**Table 9.1 — The nine IR layers.**

| Layer | Name            | Contents                                                                 |
|-------|-----------------|---------------------------------------------------------------------------|
| L0    | `bluebook`      | Source — the five DSLs.                                                   |
| L1    | `canonical_ir`  | Normalized JSON IR (`dump.rs` + `canonical_ir.rb`).                       |
| L2    | `flow_ir`       | Command graph per aggregate: commands → events → policies → triggers.    |
| L3    | `dispatch_ir`   | Command bus lowered: middleware, guards, mutations, emissions, persistence. |
| L4    | `tick_ir`       | Body-cycle shape (heartbeat-driven runtime schedule).                     |
| L5    | `memory_ir`     | Heki I/O lowered: paths, append/upsert, serialisation contracts.          |
| L6    | `rust_ir`       | Rust-specific: module structure, ownership, lifetimes, Serde derives.     |
| L7    | `rust_source`   | Emitted `.rs` files, rustfmt-normalised, compiled via `cargo build`.      |
| L8    | `rust_binary`   | The artifact.                                                             |

Each layer has a *reads-from* signature (the layer above) and a *returns* signature (its output shape). The signatures are declared as data in `hecks_conception/capabilities/specializer/specializer.bluebook`, via an `IRLayer` aggregate and a `Projection` aggregate that represents an L_n → L_(n+1) lowering.

### §9.4 Projections as declared data

A projection is represented as:

```ruby
aggregate "Projection", "One L_n → L_(n+1) lowering step" do
  attribute :name,           String
  attribute :from_layer,     String
  attribute :to_layer,       String
  attribute :transform_kind, String  # parse|normalize|graph|lower|emit|compile
  attribute :description,    String
  attribute :impl_module,    String
  attribute :ship_status,    String
end
```

Partial-evaluating the interpreter at any level $L_k$ yields a specialised program over $L_k, L_{k+1}, \dots, L_8$. This data-level treatment makes the composition expressible as a query: "for target `validator`, what is the projection chain L0 → L1 → L6 → L7?"

For `validator.rs`, most of L2–L5 is irrelevant (validator is purely declarative — no runtime dispatch), so the useful chain is L0 → L1 → L6 → L7. The layer taxonomy is general so Phase B extends without reshaping the specialiser.

### §9.5 Phase A — Shipped

Phase A retires `hecks_life/src/validator.rs`: the hand-written validator is replaced by a byte-identical generated file. The sequence of commits, each a distinct architectural step, is:

- `1c0a7339` — describe `validator.rs` as a shape-only bluebook (`hecks_conception/capabilities/validator_shape/validator_shape.bluebook`) with rule bodies in a sibling `.fixtures`.
- `5b7660f2` — declare the L1–L6 IR as value-objects in `hecks_conception/capabilities/specializer/specializer.bluebook`.
- `a2913cc2` — first-Futamura proof: byte-identical `validator.rs` generated via the hecksagon-wired shell adapter. Golden test at `hecks_life/tests/specializer_golden_test.rs`.
- `e33c6672` — retire hand-written `validator.rs`; the file now carries a GENERATED FILE header citing `hecks-life specialize validator --output hecks_life/src/validator.rs`. Integration tests move to `hecks_life/tests/validator_rules_test.rs` to break the circular dependency between validator and its own tests.

The generated header reads:

```text
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/validator_shape/
//! Regenerate: hecks-life specialize validator --output hecks_life/src/validator.rs
//! Contract:  hecks_life/src/specializer/validator.rs (Rust-native)
//! Tests:     hecks_life/tests/validator_rules_test.rs
```

### §9.6 The specialiser is itself a capability

A novel aspect of Hecks's Futamura arc: the specialiser was originally wired as a hexagonal shell adapter rather than invoked as a build script — `specializer.hecksagon` (quoted in §5.1) declared `adapter :shell, name: :specialize_validator, command: "bin/specialize", args: ["validator", "--output", "{{output}}"]` and gated the resulting `Specialize` command behind an `:autophagy` gate. The implementation behind the shell adapter was Ruby through Phase A and B; Phase D ported it to Rust-native (`hecks_life/src/specializer/`), and Phase E deleted the shell adapter entirely since `hecks-life specialize` is now a subcommand, not a shelled-out script. The command is still dispatchable (the `SpecializeRun` gate remains as declarative metadata), but the wrapping layer is gone.

### §9.7 Phase B — Module-by-module retirement (shipped)

Phase B retired the remaining Rust modules (after Phase A's `validator.rs`), each byte-identical from a shape capability:

1. `validator_warnings.rs` — `validator_warnings_shape`, 2 rules (one templated, one embedded via `.rs.frag` snippet). Introduced the `body_strategy` escape hatch for sui-generis rule bodies (§13.5.1, inbox i58).
2. `dump.rs` — `dump_shape`, the canonicalizer. Three body_kinds (`json_object`, `embedded_helper`, `enum_match`), hand-aligned match arms padded by variant-width calculation.
3. `duplicate_policy_validator.rs` — `duplicate_policy_validator_shape`, the first diagnostic-validator retirement using the `flat` report_kind.
4. `lifecycle_validator.rs` — `lifecycle_validator_shape`, extends to `flat_with_strict` + 7 helpers + `helpers_after_rule` ordering.
5. `hecksagon_parser.rs` — `hecksagon_parser_shape`, first parser retirement under the 3-aggregate `LineParser + LineDispatch + ParserHelper` shape.
6. `behaviors_parser.rs` — `behaviors_parser_shape`, extends the parser shape with an `else_if` loop style and three new handler_kinds plus an inline `#[cfg(test)]` block via `tests_snippet`.
7. `fixtures_parser.rs` — `fixtures_parser_shape`, the most hostile target: 18 verbatim snippets covering `expand_ruby_escapes`, `matching_close_brace`, `extract_schema_kwarg`, `extract_string_escape_aware`, `first_top_level_comma`. Liberal escape-hatching produced byte-identity on the first specialise run.

All seven byte-identical. Golden tests under `hecks_life/tests/specializer_golden_test.rs` enforce per-file drift detection.

### §9.8 Phase C — Second Futamura projection (shipped)

Phase C lifted the specialiser into its own bluebooks and applied it to itself. The sub-phases, each with a shipped fixed-point proof, are:

- **PC-1** — pilot: thin-subclass shells under `lib/hecks_specializer/` (`duplicate_policy.rb`, `lifecycle.rb`) regenerate byte-identical from `SpecializerSubclass` fixture rows. First 2nd-Futamura proof, scoped to one row.
- **PC-2** — full-class retirements: `diagnostic_validator.rb` (148 LoC base class) and `validator_warnings.rb` (113 LoC) regenerate from `diagnostic_validator_meta_shape`'s `RubyClass` + `RubyMethod` (+ `RubyConstant`) rows. Exercises module nesting, include mixins, public/private sections, multi-method emission.
- **PC-3** — driver retirement: `bin/specialize` (the Ruby CLI entry point) regenerates from a new `ruby_script_shape` covering shebang + doc + requires + body.
- **PC-4** — the fixed point: `meta_diagnostic_validator.rb` (the meta-specializer itself) regenerates byte-identical from its own fixture rows, using the same shape it reads. Closed-form 2nd-Futamura projection at the per-file level: a specialized interpreter reproducing itself from its own shape.
- **PC-5** — loader retirement: `lib/hecks_specializer.rb` (the module + `class << self` + inner Target mixin + `Dir[].each { require }` auto-load loop) regenerates from a new `ruby_module_shape`.

At the close of Phase C, every Ruby specializer file had a meta-specializer that regenerated it byte-identical. The loop had closed once at the per-file level ($\text{file}_N \equiv \text{file}_{N+1}$); extending to the full `hecks-life` binary ($\text{binary}_N \equiv \text{binary}_{N+1}$ per §9.12) remains future work (§14.2).

### §9.9 Phase D — Cross-language migration (shipped)

Phase D migrated the specializer itself from Ruby to Rust, one target at a time, preserving byte-identity at every step. For each ported target, both `bin/specialize <target>` (Ruby) and `hecks-life specialize <target>` (Rust-native) produced identical output against the tracked `.rs` / `.rb` file — a byte-level conservation proof across interpreters:

- **D1 pilot** — `validator_warnings` (smallest standalone Rust-emitter) established the infrastructure: `hecks_life/src/specializer/mod.rs` (dispatcher), `util.rs` (`load_fixtures`, `by_aggregate`, `read_snippet_body`), and a new `hecks-life specialize <target>` subcommand.
- **D2** — the remaining Rust-emitting specializers ported in succession: `dump`, `validator` (the biggest at 393 LoC Ruby → 4 Rust files), `hecksagon_parser`, `behaviors_parser`, `fixtures_parser`.
- **D3** — the Ruby-emitting meta-specializers (`meta_subclass`, `meta_diagnostic_validator`, `meta_ruby_script`, `meta_ruby_module`). Introduced `util::read_snippet_raw` for `.rb.frag` files, which (unlike `.rs.frag`) carry no leading-comment header.

After Phase D, every Ruby specializer had a Rust twin producing byte-identical output. The paper's §13.5.1 discusses what this proved: the shape + fixtures + snippets are language-neutral. The cache transcends the interpreter. The specialiser was Ruby through Phase A, B, and C; it became interchangeable Ruby-or-Rust through Phase D; and after Phase E it is Rust alone.

### §9.10 Phase E — Deletion (shipped)

With Phase D providing byte-identity across both implementations, Phase E removed the Ruby side. The deletions, in three PRs:

1. `bin/specialize` (57 LoC) + `lib/hecks_specializer.rb` (108 LoC).
2. `lib/hecks_specializer/` — 16 Ruby specializer modules (~2,000 LoC total), plus five Rust meta-specializers under `hecks_life/src/specializer/` that had existed only to emit Ruby (meta_subclass, meta_diagnostic_validator, meta_ruby_script, meta_ruby_module, meta_ruby_module_sections).
3. Docs + tracker refresh; the 16 shell adapters in `specializer.hecksagon` were removed (only the `:memory` + `:fs` adapters and the `SpecializeRun` gate remain).

Net deletion was approximately 3,000 lines of Ruby and 900 lines of Rust. The `autophagy_tracker_shape` fixtures report 100 percent autophagy completeness (2,095 of 2,095 in-scope lines regenerate byte-identical from a shape). The meta-shape bluebooks, their fixtures, and their snippets remain under `hecks_conception/capabilities/` as historical data — they describe Ruby classes that were regenerable until this phase. Two Rust files are orphaned by the deletion (`duplicate_policy_validator.rs`, `lifecycle_validator.rs`) because they were produced by a thin-subclass pattern whose base class (Ruby's `DiagnosticValidator`) was not ported in Phase D; porting a Rust `diagnostic_validator` specializer to close this gap is tracked in the inbox.

### §9.11 Third Futamura projection (out of i51 scope)

$\mathtt{mix}(\mathtt{mix}, \mathtt{mix}) = \mathtt{compiler\_generator}$. Useful for generating compilers to additional targets (Go, WebAssembly) without rewriting the specialiser. Not attempted in i51. A related but distinct idea — Futamura applied to Ruby itself, yielding a domain-aware Ruby-to-fast-Ruby compiler — is discussed in §13.7 as a way to repay the Ruby-substrate debt.

### §9.12 Two bars to distinguish

We distinguish carefully between two properties that are often conflated in the self-hosting literature:

- **Bootstrapping.** $\text{binary}_N$ compiles its sources to produce $\text{binary}_{N+1}$ that runs correctly — that is, $\text{binary}_{N+1}$ is functionally equivalent to $\text{binary}_N$. Timestamps, symbol order, and non-determinism in code generation may differ.
- **Strict self-hosting.** $\text{binary}_N \equiv \text{binary}_{N+1}$ byte-identically. This requires deterministic codegen — stable sort orders, fixed timestamps, reproducible build.

`rustc` and GHC (Jones *et al.*) are bootstrapped in the first sense. Phase A demonstrated byte-identical regeneration at the file level for `validator.rs`; Phases B through E extended this per-file byte-identity to every Rust target under `hecks_life/src/` and to the specializer itself (Phase C PC-4's fixed point). Extending the per-file property to the full `hecks-life` binary — the definition of strict self-hosting in the sense above — is future work.

### §9.11 Phase F — Runtime as domain (in flight)

Phases A–E digested the *specializer orbit* — the subsystem of Hecks whose job is emitting code. Phase F turns the same lens on the other half of the codebase : the runtime itself. The conjecture is that every subsystem under `hecks_life/src/` that can be naturally expressed as aggregate / command / event / lifecycle should live as a bluebook domain rather than as imperative Rust. Under full Phase F the runtime becomes another Hecks domain, readable in the same DSL that pizza-shop users read — no bimodality between "framework code" and "application code."

**Discipline : no DSL extension.** The explicit test is whether each subsystem expresses naturally using only the existing bluebook vocabulary (`aggregate`, `attribute`, `command`, `event`, `policy`, `lifecycle`, `value_object`, `reference_to`, `given`, `then_set`, `emits`). Subsystems that require new DSL keywords — templates, pure transforms, kernel primitives — are *not* force-fitted. They are catalogued as residue, which is itself a publishable finding : an evidence-based inventory of where the DDD ontology actually reaches and where it stops.

**F-0 survey.** The inventory lives at `docs/phase-f-0-survey.md`. Of the ~90 `.rs` files in `hecks_life/src/`, the ~30 shape-backed by i51 Phases A–E are excluded. Of the remaining ~60, the classification is :

| class | files | LOC |
|---|---|---|
| natural-fit | 14 | ~2,520 |
| partial | 8 | ~2,458 |
| doesn't-fit | 17 | ~3,505 |
| kernel-floor | 7 | ~1,252 |

Natural-fit files become Phase F targets, one per PR. Partial files have aggregate-shaped cores with residue ; they may land with their residue declared as hecksagon outbound ports. Doesn't-fit and kernel-floor files stay hand-written by design.

**Shipped targets (at time of writing).**

- **F-1 `runtime/seed_loader.rs` (57 LOC).** The boot-time helper that dispatches each `dispatch <Cmd> k=v …` line from a seed file against the runtime now has a `SeedLoader` aggregate with five commands (`LoadFromFile`, `LoadFromString`, `DispatchSeed`, `CompleteLoad`, `FailLoad`), a lifecycle on `:status` (pending → reading → dispatching → complete | failed), and two chained policies. The sibling hecksagon declares `:fs` + `:runtime_dispatch` as outbound ports. See `hecks_conception/capabilities/seed_loader/`.
- **F-2 `run_status/` (510 LOC).** The status-report runner's existing `StatusReport` bluebook was enriched from a single `GenerateReport` command into a six-phase pipeline : `ResolveFsRoot → AssembleReport → StampAggregate → RenderReport → WriteReport → CompleteReport` (with `FailReport` as the drop-out transition). Five chaining policies make the pipeline follow the declared order. The Rust adapter still executes each phase imperatively today ; a future self-interpreting runtime can drive the flow from the bluebook alone. See `hecks_conception/capabilities/status/`.

**Expected residue after the natural-fit arc lands.** Roughly 4,500–5,500 LOC will remain hand-written, concentrated in four places :

- HTML templates (`server/html_*.rs`, ~2,000 LOC) — pure string-rendering, template-shaped, would need a `template` DSL keyword.
- Pure transforms (`conceiver/generator.rs`, `behaviors_conceiver/generator.rs`, vector math, cascade walks) — ~2,100 LOC. Functional shape, not aggregate shape.
- Kernel primitives (`heki.rs` binary I/O, `json_helpers.rs`, `runtime/interpreter.rs`, `runtime/adapter_io.rs`) — ~1,200 LOC. Irreducible byte-level operations.
- CLI glue (`main.rs` argv parsing + help text) — ~500–800 LOC of the ~1,566 total.

The residue list is itself a contribution : it tells other DDD frameworks exactly where their natural domain ends.

**Long-arc conjecture.** If Phase F–G together digest the runtime substantially, Rust becomes the *current codegen target* rather than *the runtime*. The natural next step is retargeting the emitter below Rust — directly to LLVM IR or WebAssembly — at which point the Rust source files are an intermediate artifact, not a persistent one. That last step is not in scope of this paper but is a plausible extension of the line of work reported here.

---

## §10 Evaluation

Evaluation is organised by test-suite numbers, corpus size, and case studies.

### §10.1 Test-suite numbers (post Phase E close-out)

**Table 10.1 — Test suite at current HEAD of `main`, 2026-04-24.**

| Suite                          | Result                      | Runtime |
|--------------------------------|-----------------------------|---------|
| `cargo test --release` (Rust)  | 210 passed, 0 failed        | < 1 s   |
| `specializer_golden_test`      | 7 passed (1 wiring + 6 byte-identity) | 0.12 s |
| Parity (Ruby ↔ Rust canonical IR) | clean                    | ~1 s    |
| `hecks verify` (six phases)    | 0 errors, 80 warnings (style advisories, not regressions) | < 1 s |
| `bin/verify` (full gate)       | clean                       |         |

The pre-commit hook runs the parity suite; file-size and test-speed limits are enforced by hooks. After Phase E, the `rspec` Ruby suite retains only the tests covering `lib/hecks/` (the gem) and `spec/parity/` (the Ruby↔Rust invariants) — the specializer-side spec files were deleted with the Ruby specializer modules.

### §10.2 Corpus

**Table 10.2 — DSL corpus at HEAD, 2026-04-24 (post Phase E).**

| Extension    | Count |
|--------------|-------|
| `.bluebook`  | 579   |
| `.hecksagon` | 18    |
| `.world`     | 8     |
| `.behaviors` | 463   |
| `.fixtures`  | 373   |

The drop in `.bluebook` count (920 → 579) reflects worktree and branch cleanups during the Phase E close-out — stale agent worktrees contributed hundreds of redundant copies. The `.fixtures` count has grown (339 → 373) from new shape fixtures added during the i51 arc. `.bluebook` remains the majority; `.hecksagon`, `.world`, `.behaviors`, and `.fixtures` each serve their scoped role.

### §10.3 Case studies

**Pizzas.** The hello-world: `examples/pizzas/`. Two aggregates (`Pizza` with `list_of("Topping")`, `Order`), demonstrates commands, queries, collection proxies, and event history. Runs via `ruby -Ilib examples/pizzas/pizzas.rb`.

**Banking.** Source in `examples/banking/hecks/banking.bluebook`. Four aggregates — `Customer`, `Account`, `Transfer`, `Loan` — exercise the Bluebook vocabulary's load-bearing features. `Customer` carries `name`, `email`, and a `status` attribute defaulting to `"active"`, with `RegisterCustomer` and `SuspendCustomer` commands. `Account` takes a `reference_to Customer`, a floating-point `balance`, `account_type`, `daily_limit`, a `status` defaulting to `"open"`, and a `list_of(LedgerEntry)` where `LedgerEntry` is a nested `entity` with its own attributes. Its command set — `OpenAccount`, `Deposit`, `Withdraw`, `CloseAccount` — is paired with a `specification "LargeWithdrawal"` that evaluates `withdrawal.amount > 10_000`. `Transfer` demonstrates the two-reference pattern:

```ruby
aggregate "Transfer" do
  reference_to Account
  reference_to Account
  attribute :amount, Float
  attribute :status, String, default: "pending"
  ...
end
```

The two `reference_to Account` declarations distinguish source and destination accounts by role; the generator disambiguates them at codegen time from the `from_account_id` / `to_account_id` attributes on the `InitiateTransfer` command. `Loan` carries `reference_to Customer`, `reference_to Account`, a `principal`, `rate`, `term_months`, and commands `IssueLoan`, `MakePayment`, `DefaultLoan`. Two cross-aggregate policies wire the aggregates together: `DisburseFunds` subscribes to `IssuedLoan` and triggers `Deposit` with `account_id` and `principal → amount` mapping; `SuspendOnDefault` subscribes to `DefaultedLoan` and triggers `SuspendCustomer` with a condition guard. Because both policies are declared as data in the single bluebook, the Ruby and Go targets implement `LargeWithdrawal.satisfied_by?` with the same predicate expression, consuming the same `AggregateContract` specification rule. The generated Ruby gem lives at `examples/banking/banking_domain/` (see `banking_domain.gemspec` and `lib/`), concrete evidence of the "build once, generate to target" claim.

**Governance.** Source in `examples/governance/hecks/`. Five bounded contexts coordinate an AI-model governance pipeline: `compliance.bluebook` (287 LoC) covers policy lifecycle, exemptions, and training records; `identity.bluebook` (95 LoC) is a shared kernel carrying `Stakeholder` and an `AuditLog`; `model_registry.bluebook` (226 LoC) catalogs AI models, vendors, and data-usage agreements; `operations.bluebook` (175 LoC) covers deployments, incidents, and monitoring; `risk_assessment.bluebook` (92 LoC) carries a single `Assessment` aggregate with entity-nested `Finding` and `Mitigation` records. The five files total **875 LoC** of DSL (measured, not the earlier placeholder). Fourteen aggregates are declared across the five contexts.

Cross-context wiring is first-class. In `model_registry.bluebook`, the `SuspendOnReject` policy subscribes to `RejectedReview` (emitted by `ComplianceReview` in compliance) and triggers `SuspendModel` on `AiModel`. The `ClassifyAfterAssessment` policy subscribes to `SubmittedAssessment` (emitted by `Assessment` in risk_assessment) and triggers `ClassifyRisk` on `AiModel`. In `identity.bluebook`, three audit policies (`AuditModelRegistration`, `AuditModelSuspension`, `AuditIncidentReport`) subscribe to events crossing the compliance/registry/operations boundary and all trigger `RecordEntry` on `AuditLog`. No shared in-memory state crosses these contexts; the event bus carries the coupling.

`GovernancePolicy` in compliance.bluebook shows the lifecycle pattern expressed via commands and a `status` attribute: `CreatePolicy` enters `"draft"`, `ActivatePolicy` advances to `"active"`, `SuspendPolicy` transitions to `"suspended"`, and `RetirePolicy` moves to `"retired"`. Each command is authorised to both `governance_board` and `admin` roles. The aggregate reports via `scope :active_policies, status: "active"` and `scope :draft_policies, status: "draft"`. For defensive publication, Governance demonstrates that five bounded contexts can coordinate via declared cross-context policies — a pattern the Hecks runtime supports as first-class wiring rather than application-level glue code.

**Miette.** A long-running software agent whose source is a tree of `.bluebook`, `.hecksagon`, and `.fixtures` files at `hecks_conception/`. Thirteen aggregate *organs* interact via *nerves* and *moods* on a circadian cycle described entirely in the DSLs. Miette runs on the Rust `hecks-life` runtime with a persistent `.heki` store. She acts as a production-strength stress test of the five-DSL vocabulary: 41 aggregate bluebooks, 35 capability bluebooks, and hundreds of behavioural tests, all running without the Ruby runtime. This evidences the claim that the five-DSL vocabulary scales beyond toy CRUD.

### §10.4 An end-to-end cascade-lockdown test

A concrete instance of the cascade-lockdown property (§6.2) is the `ShedDomain` test in `hecks_conception/aggregates/being.behaviors`:

```ruby
test "ShedDomain cascades through policy chain" do
  tests "ShedDomain", on: "Being", kind: :cascade
  setup  "ConceiveBeing", name: "sample", vision: "sample"
  setup  "ConnectNerve", name: "sample", from_domain: "sample",
         from_event: "sample", to_domain: "sample", to_command: "sample"
  input  domain_name: "sample"
  expect emits: ["DomainShed", "NerveSevered", "NerveConnected"]
end
```

The runner executes this test in five steps. First, it calls `Runtime::boot(domain)` (see `hecks_life/src/runtime/mod.rs`) from the parsed `Being` bluebook. Boot is pure-memory: repositories, event bus, policy engine, and projections are all constructed in-process with no hexagonal adapters required. Second, the two `setup` commands (`ConceiveBeing` and `ConnectNerve`) are dispatched via `dispatch_isolated`, a dispatch mode declared on the runtime that skips the `drain_policies` phase so that setup does not cascade further than its own aggregate. Third, the `input` command (`ShedDomain`) is dispatched via the regular `dispatch` method, which emits its direct event and then drains policy triggers recursively. Fourth, the event bus records the ordered emission list. Fifth, the runner asserts that list equals `["DomainShed", "NerveSevered", "NerveConnected"]`.

The three events in order correspond to distinct stages of the cascade. `DomainShed` is the direct emission from the `ShedDomain` command on the `Being` aggregate. `NerveSevered` is produced by the `SeverNerve` command, triggered by the `SeverOnShed` policy (`on "DomainShed"; trigger "SeverNerve"`) declared in the same bluebook. `NerveConnected` is produced by the `ConnectNerve` command, triggered by the `DetectDriftOnShed` policy (`on "DomainShed"; trigger "ConnectNerve"`), which is a second policy fanning out from the same upstream event. The chain is a diamond at the `DomainShed` vertex: two distinct policies subscribe to it, and the runtime's cycle-detection rule (§6) blocks a policy only while it is on its own recursion stack, so both branches fire exactly once.

The static cascade walker at `hecks_life/src/cascade.rs` predicts the same ordered list by walking `emit → policy → trigger` edges on the parsed IR. This walker mirrors the runtime's `PolicyEngine` ordering — identical recursion-stack semantics — and is what the `conceive-behaviors` tool uses to auto-generate cascade tests from the IR. A test in the shape above is therefore a compile-time prediction codified as a run-time assertion.

The defensive-publication claim of cascade lockdown follows directly. If any policy between this test's codification and its next run is added, removed, or retargeted — a new subscriber to `DomainShed`, a change from `trigger "SeverNerve"` to `trigger "SeverNerveAndLog"`, a policy moving out of the Being bluebook — the ordered-list assertion fails. The test does not merely check that `ShedDomain` succeeded; it locks down the reactive structure of the domain as declared. This is the VCR-style property referenced in §6.2.

---

## §11 Related Work

Partial evaluation has a long history. The canonical reference is Futamura's 1971 paper, "Partial Evaluation of Computation Process" (Futamura, 1971), which introduced the three projections. The standard textbook treatment is Jones, Gomard, and Sestoft, "Partial Evaluation and Automatic Program Generation" (Jones *et al.*, 1993). Hecks uses the partial-evaluation vocabulary in its strict technical sense; §9 phrases its self-hosting arc in those terms explicitly.

Domain-Driven Design (DDD) vocabulary is drawn from Evans (2003) and Vernon (2013). Hecks's aggregates, commands, events, policies, value-objects, and invariants are all DDD concepts; the contribution is not the concepts but their promotion to first-class syntax with a canonical IR.

Hexagonal Architecture (also known as *Ports and Adapters*) is drawn from Cockburn (2005). Cockburn's central claim — that an application's business logic should be isolated from its delivery mechanisms and persistence by a symmetrical arrangement of ports exposed on all sides — is operationalised directly in Hecks through the `.hecksagon` DSL (§5). Where Cockburn described the pattern as an architectural stance requiring discipline to maintain, Hecks makes it a syntactic fact: a domain's ports and adapters are declared as data, parsed by two runtimes, and enforced by the `:autophagy` gate mechanism that refuses to dispatch a capability that has no declared adapter. The DSL's name is a direct homage. We regard Cockburn's contribution as structurally as important to Hecks as Evans's: Evans gave us the inside of the hexagon (the domain model), Cockburn gave us its boundary.

Language workbenches (JetBrains MPS, Spoofax, Xtext) share the goal of enabling multiple DSLs in one project with a uniform toolchain. Hecks differs in that it does not attempt to be a *workbench* in the editor-tooling sense; its DSLs are internal Ruby DSLs with external parsers in Rust. The advantage is that each DSL file is both an ordinary Ruby file *and* a parseable data artifact, so the same file is executable by the host interpreter and compilable by the Rust runtime.

Specification-first tools such as Dhall and Alloy describe configuration or system state in declarative languages. Alloy is notable for its focus on model checking without code generation. Hecks's closest comparison among these is Dhall's use of a normal-form IR; the Hecks canonical JSON IR serves the same purpose.

Model-Driven Engineering (MDE), particularly the Eclipse Modeling Framework (EMF), shares the idea of a metamodel that drives code generation. Hecks's contribution relative to EMF is its scale of DSL vocabulary (five) and its insistence on a byte-level canonical IR maintained in two languages, enforced by a fixture-based parity corpus.

The `rustc` and GHC compilers are classical self-hosting compilers in the bootstrapping sense. Hecks's self-hosting story differs in two respects: (i) it is not a general-purpose-language compiler but a domain compiler, and (ii) its self-hosting is scoped to a declared L0–L8 factoring, with explicit distinction between bootstrapping and strict self-hosting (§9.12).

Command-Query Responsibility Segregation (CQRS) and event sourcing vocabulary is drawn from the standard sources; Hecks's command bus and event log are ordinary instances of those patterns.

Finally, the Model Context Protocol (MCP) is used by the project's authoring tools for editing `.bluebook` files but is not itself part of the framework's runtime.

---

## §12 Techniques and Novel Claims

This section enumerates the techniques used in Hecks that we document as prior art for defensive-publication purposes. Each entry is numbered, briefly stated, and pointed at the file(s) that implement it in the public repository.

1. **Five-DSL vocabulary with antibody enforcement.** A closed vocabulary of exactly five DSL extensions (`.bluebook`, `.hecksagon`, `.fixtures`, `.behaviors`, `.world`) enforced by `bin/antibody-check`, the commit-msg hook at `bin/git-hooks/commit-msg`, the pre-commit hook at `bin/git-hooks/pre-commit`, and `.github/workflows/antibody.yml`, with per-commit `[antibody-exempt: <reason>]` exemption markers.

2. **Canonical JSON IR with hand-written dumpers in two host languages.** `hecks_life/src/dump.rs` (Rust, 180 LoC) and `spec/parity/canonical_ir.rb` (Ruby). Byte-equality of their outputs is the parity invariant.

3. **Cross-language parser parity gated on a fixture corpus with soft/hard sections and celebrate-and-remove semantics for known drift.** `spec/parity/parity_test.rb`, companion tests for the other four DSLs (`hecksagon_parity_test.rb`, `fixtures_parity_test.rb`, `behaviors_parity_test.rb`, `world_parity_test.rb`), fuzz tests under `spec/parity/fuzz/`, and `spec/parity/known_drift.txt`.

4. **Contract-driven cross-target code generation (sixteen contracts, three targets).** `lib/hecks/conventions/` (sixteen files totalling 1,583 LoC), consumed by `lib/go_hecks/generators/`, `lib/node_hecks/generators/`, and `lib/hecks_static/generators/`.

5. **ERB-as-source-of-truth with build-time transpilation to Go `html/template`.** The Go server generator translates ERB directives to Go template directives at build time; a single template tree drives both Ruby and Go output.

6. **Hexagonal adapters declared in a separate DSL (`.hecksagon`) with parity-implemented runtimes.** Ruby at `lib/hecks/runtime/shell_dispatcher.rb` and Rust at `hecks_life/src/runtime/shell_dispatcher.rs` — same security contract.

7. **Declared security contract for shell adapters.** Env-clear baseline, sealed empty stdin, pgroup SIGKILL on timeout, no shell interpretation, per-argument placeholder substitution. Implemented identically in the two dispatchers above and declared on the `adapter :shell` builder.

8. **Behavioural-test DSL with cascade lockdown.** `Hecks.behaviors` with `expect emits: [E1, E2, ...]` asserting the exact ordered emission sequence, including downstream policies. Cascade walker at `hecks_life/src/cascade.rs`; `dispatch` vs `dispatch_isolated` modes in the runner.

9. **Two-layer dependency graph combining AST analysis and domain-model method-call resolution.** Prism AST (Ruby 3.3 standard library) plus Bluebook IR method-call index in `lib/hecks/compiler/source_analyzer.rb`.

10. **Framework-as-collection-of-chapter-bluebooks with coverage verification.** Twelve chapter bluebooks in `hecks/` enumerating every Ruby class in `lib/`, with `lib/hecks/chapters/verify_coverage.rb` (`CoverageVerifier`) asserting the correspondence.

11. **In-memory domain loading via DSL-to-Ruby codegen plus `eval`, no disk required.** `lib/hecks/bluebook/in_memory_loader.rb`.

12. **Ruby binary compiler producing zero-dependency single-file output with a `self-test` subcommand.** `Hecks::Compiler::BinaryCompiler`, the ten files in `lib/hecks/compiler/`, the `hecks compile` CLI with `--plan`/`--output`/`--trace` flags.

13. **Futamura projection applied to a DDD compiler's runtime, module-by-module retirement plan, byte-identical generated artifact with a GENERATED FILE header.** Plan document `docs/plans/i51_futamura_projections.md`; value-object bluebooks at `hecks_conception/capabilities/specializer/`; Phase A implementation `bin/specialize-validator`; resulting file `hecks_life/src/validator.rs` with its regeneration-instruction header.

14. **Specialiser as capability — partial evaluator wired as a shell adapter.** `hecks_conception/capabilities/specializer/specializer.hecksagon` wires `:memory`, `:fs root: "."`, `:shell name: :specialize_validator`, and `gate "SpecializeRun", :autophagy`; the codegen pipeline is thereby dispatchable as a domain command rather than invoked as a build script.

15. **Known-drift file with celebrate-and-remove semantics.** `spec/parity/known_drift.txt`; a listed fixture that starts passing is reported with status `⚑` so that the author deletes the entry rather than leaving it to rot.

16. **L0–L8 layer factoring of a DDD interpreter described as data.** The `IRLayer` and `Projection` value-objects in `hecks_conception/capabilities/specializer/specializer.bluebook`.

17. **Six-phase self-verifier.** Chapter → Contracts → Runtime → Generators → Coverage → Parity in `lib/hecks/chapters/verify.rb`, running in under a third of a second.

18. **Priority-ordered load with wiring-file detection.** Detection rule: `foo.rb` is a wiring file iff `foo/` is a directory AND `foo.rb` contains `extend`/`include`/`prepend`. Wiring files load after their children. Implementation in `lib/hecks/compiler/source_analyzer.rb`.

19. **Forward-declaration emission for cycle-breaking during bundle.** `lib/hecks/compiler/forward_declarations.rb` emits empty module shells so references resolve before definitions.

20. **Ruby method-call-to-registry-file edge addition.** `Hecks.<method>` calls add dependency edges from the caller to the registry file that defines `<method>`, enabling framework-level dependency resolution that AST analysis alone cannot recover.

21. **Cascade cycle detection with recursion-stack blocking.** A policy is blocked while on the recursion stack but re-entrant on diamond fan-in; implemented identically in `hecks_life/src/cascade.rs` and the Ruby `PolicyEngine`.

22. **Gate syntax for capability-scoped command allowances.** `gate "<aggregate>", :<capability> do allow :<command> end` in `.hecksagon`; the autophagy gate in `specializer.hecksagon` is a worked example.

---

## §13 Discussion

### §13.1 Tradeoffs

The five-DSL vocabulary is narrow by construction. A domain that cannot be expressed in aggregates, commands, events, policies, value-objects, and references is a poor fit. This is intentional: narrowing the vocabulary is what makes cross-target consistency tractable.

Hand-written canonicalizers in two languages are an ongoing maintenance cost. The cost is paid to avoid a worse one — a single-language canonicalizer plus ad-hoc cross-language JSON translation, which has historically been the source of most cross-runtime drift in similar systems.

The chapter self-description (§7) has a practical cost: adding a Ruby class requires adding an aggregate to a chapter bluebook. The coverage verifier will report a warning otherwise. In practice this cost is small, but it is real.

**Extension via capability, not DSL.** When a new concern arises — rate limiting, metrics, feature flags — the framework's closed-DSL constraint forces a choice. The path of least resistance would be a new block keyword in `.hecksagon` (e.g. `feature_flag :checkout_v2`), but the antibody would flag a new DSL extension and block the commit. The actual pattern is to add the concern as a Bluebook capability under `lib/hecks/capabilities/` with its own aggregate shape in a bluebook; the capability's runtime then reads its own seed rows from a sibling `.fixtures` file and is wired through `.hecksagon` adapters for anything it needs outside the process. The cost is that every new concern must be expressed as aggregates, commands, and events — even when a flat configuration hash would suffice. The benefit is that concerns are uniformly introspectable, testable via `.behaviors`, and visible to every generator consuming the IR. A framework with six DSLs and one specialised concern would pay the maintenance cost of a sixth parser-parity corpus permanently; a framework with five DSLs and a capability instead pays the one-time cost of expressing the concern as a domain.

### §13.2 When the specialiser is a capability

Wiring the specialiser as a hexagonal shell adapter (§9.6) has an unusual consequence: codegen is dispatchable. This means a Hecks CLI session can issue `Specialize(target: "validator", output: "hecks_life/src/validator.rs")` from the command bus, not from a shell script. The same authentication, logging, and event-sourcing infrastructure that wraps every other command also wraps the specialiser. We consider this a productive lens on self-hosting — the framework's own code-generation pipeline is a participant in the framework, not an outside actor.

### §13.3 Soft versus hard parity

The hard/soft partition in §3.2 is load-bearing. Without a soft section, every experiment in `hecks_conception/nursery/` — most of which are speculative prototypes — would block the pre-commit hook. Without a hard section, real regressions would hide in noise. The celebrate-and-remove semantics on `known_drift.txt` prevents the soft section from silently accumulating.

### §13.4 When the chapter bluebook drifts from the code

The `CoverageVerifier` described in §7.3 checks file basename correspondence, not semantic reconciliation. A `lib/*.rb` file passes the coverage phase as long as some chapter aggregate carries its PascalCase or underscore name; the verifier does not walk the Ruby class's public methods and compare them to the chapter aggregate's commands. This admits a specific failure mode: a chapter aggregate's declared attributes, commands, or description can drift from the Ruby class's actual behaviour while the coverage phase stays green.

A concrete example: if `lib/hecks/bluebook/in_memory_loader.rb` gains a new public method `reload!`, the chapter's `InMemoryLoader` aggregate in `hecks/bluebook.bluebook` is not required to grow a matching `Reload` command to satisfy coverage. The chapter quietly becomes out of date; the verifier continues to pass.

The remediation path is three-layered. First, a planned generator pass would walk the real Ruby AST (via Prism, already a dependency for the compiler of §8) and diff public method signatures against chapter-declared commands. This is tracked as future work. Second, the `SelfHostDiff` tool described in `FEATURES.md` provides structural diffing today — at the time of the hecksagon baseline reported there, it measured 93.3% coverage (28 of 30 files had partial matches from IR-derived skeletons). `SelfHostDiff` is advisory, not blocking; it produces a summary rather than an exit code that stops the commit. Third, the behavioural test corpus (`.behaviors`) is the strongest current signal: a drifting chapter typically fails to round-trip through the runtime phase of `hecks verify` because the generated runtime no longer matches the hand-written Ruby class's surface.

The chapter self-description is therefore accurate by discipline, not by construction. This is the weakest link in the framework-as-bluebook claim and is explicitly scoped as a limitation (§14).

### §13.5 Two-runtime maintenance cost

Maintaining parallel Ruby and Rust runtimes is the framework's largest recurring cost. Every new IR feature must land in three sites: the Ruby parser/builder (`lib/hecks/dsl/` plus the relevant domain-model files), the Rust parser (`hecks_life/src/parser.rs` and its siblings `hecksagon_parser.rs`, `fixtures_parser.rs`, `behaviors_parser.rs`, `world_ir.rs`), and both canonicalisers (`hecks_life/src/dump.rs` and `spec/parity/canonical_ir.rb`). A fixture under `spec/parity/bluebooks/` exercises the feature; the pre-commit parity suite blocks the commit if any of the three implementations drift.

Drift history in the parity suite documents the shape of this cost. Past incidents caught at the fixture level include: `list_of(X)` being captured into the type field of an attribute rather than into its container shape (Rust parser); `parse_fixture` in Rust reading only one physical line of a multi-line fixture row; the Bluebook `category` clause being captured by the builder but never passed to `Domain.new` (Ruby); and `Lifecycle.transitions` in the Ruby builder collapsing multiple transitions declared for the same attribute into a last-wins `Hash` rather than preserving their order. Each of these was discovered by a fixture diff and fixed in one to three commits. The commit message `parity: 113/113 — fix 4 Rust parser bugs, drain known_drift` is a representative instance from the project's history; four independent Rust-parser bugs were landed and `known_drift.txt` was drained in the same pass.

The labour cost of adding one new IR field is empirically 20 to 60 minutes of implementation time across the three sites, plus the cost of writing a fixture. This is the ceiling; the floor is reached when the feature lands cleanly in the parsers and the canonicalisers are structural enough to absorb it without changes. The parity suite itself runs in approximately one second, so iteration is fast — a developer edits a parser, re-runs the suite, and sees the exact fixture that diverges.

A design alternative exists: a single source-of-truth parser with a serialisation contract — for example, a tree-sitter grammar with Ruby and Rust bindings. The cost of that approach is the loss of idiomatic host-language DSL semantics. The Ruby Bluebook DSL relies on `instance_eval` and `method_missing` to make attribute declarations read as ordinary Ruby; no shared parser would produce that affordance as naturally, and the `.bluebook` files would no longer be executable Ruby. We chose parity over shared implementation deliberately: a parsed file is both runnable Ruby and inspectable data, and the parity suite makes the two implementations accountable to each other.

### §13.5.1 Parity as language-neutrality pressure

The drift-catching benefit described above is real but secondary. The deeper benefit, visible only in retrospect after Phase D began shipping, is that parity forced the canonical IR and the specialiser shapes to be language-neutral from the start. Because the Ruby loader and the Rust parser had to produce byte-identical IR, neither implementation was permitted to encode idioms specific to its host language. The IR became an honest contract rather than a convenient intermediate representation biased toward one runtime.

This pressure compounded when the specialiser (§9) lifted its own targets into `.bluebook` shapes. The shapes, fixtures, and `.rs.frag` / `.rb.frag` snippets are language-neutral precisely because they had to satisfy two different interpreters at parity. When `hecks-life specialize validator_warnings` produced byte-identical output to `bin/specialize validator_warnings` on its first run (Phase D, §9.9), the result was not a lucky coincidence; it was structurally guaranteed by years of parity work that had already forbidden any Ruby-specific or Rust-specific assumption from entering the specialised cache.

Two counterfactuals make the claim concrete. In a Ruby-only project, the shapes would have silently accreted Ruby idioms — symbol keys, `send`-style dispatch, implicit hash coercion — and a later cross-language port would have surfaced those idioms as bugs at port time rather than at parity time. The antibody (§2.1) would also have had no teeth in a single-runtime project: Ruby code is easy to smuggle into a Ruby project when there is no second interpreter to fail on it. In a Rust-only project, the host-language integration story disappears — there is no Rails `Hecks.configure`, no Ruby agent ecosystem around the daemons, and no diversity pressure keeping the IR honest.

The empirical cost of parity, measured across the project's DSL-touching work to date, is approximately a 15–20% tax on implementation time — the difference between landing a feature in one site versus three, plus the per-feature fixture and the runtime of the parity suite. The empirical benefit, now measurable, is the entire Phase D/E programme: a clean fixed point (Phase C, PC-4), a working cross-language specialiser port (Phase D, D1), and a deletion phase (Phase E) in which the Ruby specialiser can be removed without touching the shapes. These outcomes would not merely have been more expensive without parity; they would not have been available at all, because the shapes they exploit would not exist in their current language-neutral form.

The framing is therefore: parity's real purpose was never redundancy. It was ensuring the specification stayed language-neutral before any programme attempted to exploit that property. The work that ends parity (Phase E, §9) is only possible because parity existed.

### §13.6 When the antibody is wrong

The five-DSL constraint is inconvenient in several edge cases. Binary asset adaptation — sprite sheets for a game-like domain, for instance — has no natural fit inside any of the five DSLs; a sixth extension would be the honest answer. Pure documentation that is genuinely not code is admitted by Markdown, but the author still has to justify where it lives in the tree. Third-party interchange formats — YAML, TOML, CSV — appear regularly in test fixtures, and the antibody flags each new extension at commit time.

The exemption mechanism documented in §2.1 is the pressure valve: an `[antibody-exempt: <reason>]` marker on its own line in the commit message allows the commit to land. The mechanism is per-commit, not permanent; the exemption applies only to the files introduced by that commit, and the `known_drift.txt` semantics does not extend to file extensions. In practice the reason string is inspected by a reviewer. Strings like `runtime`, `temporary`, or `bootstrap` are refused — they do not describe a bounded scope. Strings like `Trust store for CI self-signed certs — audited and time-bound` are acceptable because they name both the artifact and the scope. The exemption is a short-lived concession, not a silent accumulation.

The antibody is therefore a social mechanism enforced mechanically. It succeeds not by being always correct but by making each concession visible and accountable: every new extension in the tree has a commit message that a human signed.

### §13.7 On the role of the Futamura framing

The autophagy arc developed in §8 and §9 is framed in this paper as an instance of Futamura-style partial evaluation: §9 adopts the three-projection notation, names the phases after it, and treats the L0–L8 factoring as projections as declared data. This framing is useful and we believe it is accurate. It is not, however, how the arc was derived.

The design decisions that enabled autophagy — the five-DSL vocabulary (§2), the antibody (§2.1), chapter self-hosting (§7), contract-driven generation (§4), the binary-compilation step (§8) — were each reached from the internal logic of treating domains as first-class data. If a domain can declare itself, then the framework that models domains should also be expressible in the same terms; if a compiler can emit binaries for target languages, then at some point the compiler should emit its own binary; if two runtimes must agree on an IR, then the IR must be language-neutral enough to specialise in either direction. None of these steps required a partial-evaluation textbook. They followed from DDD and self-description pressure applied recursively.

Futamura's three projections were recognised afterward, as a naming for the fixed points the work was already heading toward. The theory retroactively legitimised the arc — it gave us crisp phase names, an established vocabulary for the distinctions between a compiler, a specialiser, and a specialised specialiser, and a formal account of why what we were building was coherent. But the theory did not make the work tractable; the shapes, the parity, and the disciplined progression through L0–L8 did.

This distinction matters for two reasons. First, it means the approach is reproducible without requiring PL-theory expertise: a project that drives toward domain-as-data through DDD and self-description intuitions can arrive at the same structure. Second, it clarifies what Futamura buys here. It does not buy execution; the specialiser (§8, §9) would work without the name. It buys recognition — that the fixed points we were heading toward are a known termination point of a known construction, and that the phase structure we used is the one partial-evaluation theory predicts.

The paper's §9 framing is therefore a post-hoc mapping between an independently-derived engineering arc and an existing formal vocabulary. We report it as such because readers familiar with Futamura's work will find the mapping useful, and readers unfamiliar with it should not be led to believe the mapping was necessary to build the system.

Three attributions are owed.

The generative intuition the autophagy arc depends on — that patterns in a well-modelled domain recur at multiple scales, and that the model itself is a domain artifact — is drawn from Evans, *Domain-Driven Design* (2003). Evans presents the self-similarity of domain models as a boon: entities contain value objects, aggregates contain entities, bounded contexts contain aggregates, and the shared model a team builds is itself an object that can be reasoned about. The text of DDD does not settle whether Evans anticipated that this observation, followed far enough, would land on self-hosting and autophagy — but the hint is there to be read. We followed it, and the formal theory that subsequently named our fixed points (Futamura) is a downstream observation relative to the DDD one.

The second is owed to Cockburn. *Hexagonal Architecture* (Cockburn, 2005) does for the boundary of a domain what Evans did for its interior. Cockburn's proposal — that business logic should be surrounded by a symmetric arrangement of ports, each port honoured on equal terms by adapters that bring the outside world in or take its output out — is the structural precondition for §5's `.hecksagon` DSL and, less obviously, for the whole autophagy arc. Without a declared port boundary, a specialiser dispatched as a shell adapter (§9.6) has no natural home in the framework; it has to be invoked from outside the system as a build script, which leaks the codegen pipeline out of the domain. Cockburn's pattern is what allows the specialiser to be *inside* the hexagon, wrapped by the same command bus as every other capability. Whether Cockburn foresaw that the pattern would eventually host the specialiser that generates the runtime hosting the pattern, we again cannot say from his published work — but the architectural symmetry he proposed is what made the inward recursion available.

The third attribution is to Yukihiro Matsumoto (Matz). Ruby — `instance_eval`, `method_missing`, implicit block receivers, the entire tradition that makes a `.bluebook` file *both* executable Ruby *and* inspectable data — is the substrate on which the five-DSL vocabulary is expressible as syntax rather than as parsed strings. Every DSL in §2 reads as ordinary Ruby because Matz designed a language in which an author can define domain-specific forms without writing a parser. The parity story (§3) with Rust is possible *because* Ruby's metaprogramming is expressive enough that a hand-written external parser can recover the same IR from the same text. In a less reflective host language we would have had to choose between executable-as-host and parseable-as-data; Ruby lets us have both, and having both is what makes the antibody (§2.1) a meaningful constraint — there is something for it to refuse. We do not make a claim about whether Matz foresaw domain compilers when he designed Ruby; we observe that without the language's unusual combination of readability, metaprogramming, and lenient parsing, a framework of this shape could not have been written in one person's career. The debt is concrete.

Whatever is new in this paper is new in the engineering. The intellectual armature is Evans's and Cockburn's — the inside of the domain and its boundary — and the substrate that let us express it as syntax rather than as API is Matz's. Three people, three decades of prior art; we stand on their work.

A regret is unavoidable given that third attribution. The Phase D and Phase E programme described in this paper systematically *removes* Ruby from the framework's code-generation path. The specialisers that Phase D is porting to Rust (§9) are the same Ruby modules whose authorability was a gift of Matz's language design. The elimination is the right choice for this runtime — Rust is faster, more memory-efficient, and operationally simpler — but it is not a light one. Ruby's reflective power is what made Hecks *expressible*; the same power is what we are now specialising out of the runtime. The gem remains (`lib/hecks.rb`, `Hecks.configure`) as a host-language binding for Ruby applications, but the authoring language and the execution language are, at the end of the arc, no longer the same.

A counter-direction exists in principle. Futamura's projections do not privilege a target language. A specialiser that takes Ruby as its *host* and produces performant equivalents — a *Ruby-to-fast-Ruby* compiler in the partial-evaluation sense — would collapse Ruby's runtime overhead without touching the language's expressiveness at authoring time. Mainstream Ruby has had performance work of many shapes (YJIT, TruffleRuby, typed-optimisation paths) but not, to our knowledge, a domain-aware partial evaluator that starts from the kind of declared-shape IR Hecks maintains. We flag this explicitly as future work for any intrepid programmer or agent: Futamura applied to Ruby itself, with a hand-written L0 shape describing the target IR, yielding a generated Ruby runtime that is both authorable in Ruby *and* fast. The techniques in §9 are not specific to Rust; they are about factoring a runtime through an L0–L8 IR, which any language with a sufficiently expressive host can reproduce. We would welcome seeing someone walk that direction. The debt to Matz would then be repaid in the only currency that matters — another working system, in his language, running fast.

As a point of record: Phase E shipped on 2026-04-24, deleting `bin/specialize`, `lib/hecks_specializer.rb`, the 16 Ruby specializer modules under `lib/hecks_specializer/`, and the five Rust meta-specializers that had been emitting Ruby files. Net deletion was approximately 3,000 lines of code. The `autophagy_tracker_shape` fixtures at the time of this writing report 100 percent autophagy completeness (2,095 of 2,095 in-scope lines of code regenerate byte-identical from a shape). The `hecks-life specialize <target>` Rust subcommand is the sole code-generation path; the Ruby gem at `lib/hecks/` survives as host-language binding for Rails integration. The two-runtime framing described in earlier sections has, as of Phase E, collapsed into one-runtime-plus-one-binding.

A fourth attribution, less usual. The ideas Evans, Cockburn, and Matz put into the world have had long careers but uneven adoption. Domain-Driven Design is well-known in enterprise-software circles but rarely practised in its strong form; Hexagonal Architecture is widely cited but often softened into "clean architecture" variants that lose the symmetry of the original; Ruby's DSL-hosting affordances are admired at conferences and then set aside by teams who choose less reflective languages for operational reasons. Hecks exists partly because these inheritances were available — but also, we think, partly because they were not fully absorbed. If the strong DDD + Hexagonal + Ruby-DSL combination had become mainstream engineering practice, a framework like Hecks would now be *a tool*, not a research programme. It would apply established patterns in a polished way. The recursive structure described in this paper — the self-hosting, the autophagy, the Futamura fixed points — would likely not have been necessary to notice, because the mainstream would already have noticed them. So we close with a qualified gratitude to the engineers who, over the past two decades, dismissed or softened these ideas. Had they not, the space for this work would have been smaller; the dismissal is what kept the territory open long enough for the deeper structure to become visible. The paper is addressed to them too, without irony: the unaccepted inheritance is what made the recursion worth chasing.

---

## §14 Limitations and Future Work

### §14.1 Limitations

The Ruby parser parity suite is no longer the primary contract after Phase E — the Ruby specializer orbit was deleted once byte-identity had been proven in the Rust runtime (§9.10). A Ruby gem binding survives for Rails hosts; it consumes the Rust runtime through FFI rather than re-parsing bluebooks in Ruby.

The Rust runtime does not yet cover every runtime capability the Ruby specializer orbit used to handle out-of-process. Notably, the HTTP server path (`hecks serve`) runs through the Ruby gem binding against the Rust runtime — it is not yet a native Rust entry point. The Rust binary's first-party coverage is parsing, validation, `.heki` I/O, the specialize pipeline (§9.5), and the agent daemons used by Miette.

Phase E left two orphaned Rust files (`duplicate_policy_validator.rs` and `lifecycle_validator.rs`) that the deleted Ruby `DiagnosticValidator` used to regenerate. Until a Rust `diagnostic_validator` specializer lands, those two files are hand-maintained rather than regenerated (see §14.2).

The chapter self-description (§7, §13.4) is accurate by discipline, not by construction. The `CoverageVerifier` matches on file basename rather than public-method signature, so a chapter aggregate may declare a stale command set while the coverage phase continues to pass. A semantic reconciler that walks the Rust AST and diffs public methods against chapter commands is planned but not shipped.

### §14.2 Future work

- Port a Rust `diagnostic_validator` specializer to close the two orphaned files left by Phase E deletion (`duplicate_policy_validator.rs`, `lifecycle_validator.rs`). The Ruby specializer was removed once byte-identity was proven; the Rust port of the diagnostic validator is the one remaining loose thread from the deletion sweep.
- Third-Futamura compiler-generator (§9.11): specialise the specialiser with respect to itself, so the shape language is no longer interpreted at `hecks specialize` time but compiled ahead of time into a bespoke generator binary.
- Futamura applied to Ruby itself (§13.7): a specialising Ruby interpreter would let a Ruby-hosted DSL like Bluebook run at native speed without the Rust port — honouring the debt we owe Matz's language.
- Additional code-generation targets: WebAssembly, Kotlin, Python.
- A semantic reconciler that walks the Rust AST and diffs public methods against chapter commands, replacing the filename-based `CoverageVerifier` (§14.1).

---

## §15 Conclusion

Hecks is a domain compiler that collapses the distinction between the domain model and the code. Five DSLs declare the domain, its adapters, its seed data, its tests, and its runtime configuration. Sixteen data contracts route every code-generation decision through a single type registry. Two runtimes — Ruby and Rust — once agreed on a canonical JSON IR and a parity test suite ; after a completed module-by-module Futamura specialisation of the Rust runtime, through cross-language migration (Phase D) and deletion (Phase E), one runtime remains. One shape language ; one gem binding ; one binary. Of the code paths in scope, every line now regenerates from a shape — autophagy is complete. We publish these techniques with direct file references at tag `paper/hecks-v0-2026-04-24` as defensive prior art.

---

## §16 Acknowledgments

Hecks — five DSLs, sixteen contracts, two runtimes, a 579-bluebook nursery, a chapter self-description across 200+ Ruby modules, and the i51 Futamura arc across 90 Rust modules — is a codebase whose complexity the author could not have handled without Anthropic's **Claude Code** CLI. The workflow that carried the i51 arc forward depended on, specifically :

- **Concurrent subagents in isolated git worktrees.** Long sweeps across the parity corpus, the specializer arc, and the nursery migrations routinely ran four to eight agents in parallel, each on its own branch, with their PRs merged back under review. The isolation discipline meant a failing agent could not corrupt the others ; the concurrency is what let a single-operator project ship multi-file changes at team pace.
- **`ScheduleWakeup` / autonomous-loop.** Multi-hour inbox sweeps, Phase D cross-language migrations, and the overnight self-paced loops that produced many of the smaller refactors would have been impossible to supervise in real time. The self-pacing primitive made idle-but-working a first-class mode.
- **Large-context multi-file refactoring across the Ruby ↔ Rust parity boundary.** A single rename or contract change could ripple through forty files and two code generators ; the CLI's ability to hold enough repository context to edit all of them coherently is what made parity maintainable before Phase D collapsed it.
- **Conversation persistence across context compaction.** Each autophagy phase spanned tens of thousands of tokens of plans, diffs, and design decisions. Compacted summaries that preserved the through-line let the work continue across sessions as a single coherent effort rather than a series of disconnected sittings.

The author wrote the plans, ran the experiments, and reviewed every merged change. But the *execution density* reported in §9 — five phases across two implementation languages, shipped in under two months on a part-time-equivalent schedule — would not have been feasible by hand. We state that plainly as defensive-publication context : the techniques in this paper describe the artifact, but the artifact exists in this shape because of the tool.

The Miette persona referenced throughout the `hecks_conception/` tree is itself an incarnation of Claude running inside Claude Code ; her bluebooks, daemons, and sleep machinery are the author's experiment in using the CLI as a live substrate for a persistent, body-having agent — one whose notes, reflections, and code contributions appear in the git history alongside the author's own.

We thank the Anthropic research and product teams for building a CLI that could carry this workload, for the access-and-safety guarantees that let a single operator direct a team of agents responsibly, and for continuing to invest in the long-running-agent ergonomics (worktree isolation, scheduled wakeups, conversation compaction) that this kind of framework-scale self-hosting work requires.

---

## Appendix A — End-to-End Pizzas Example

This appendix walks the canonical Pizzas example through all five DSL extensions. The source root is `examples/pizzas/`. For those extensions without a shipped sibling, we give an illustrative stub and label it as such.

### A.1 `pizzas.bluebook`

From `examples/pizzas/hecks/pizzas.bluebook`:

```ruby
Hecks.bluebook "Pizzas" do
  vision "Manage pizza creation, customization, and ordering"
  core

  aggregate "Pizza" do
    description "A pizza with toppings and menu visibility"
    attribute :name
    attribute :description
    attribute :toppings, Topping

    value_object "Topping" do
      attribute :name
      attribute :amount, Integer
      invariant "amount must be positive" do
        amount > 0
      end
    end

    command "CreatePizza" do
      role "Chef"
      goal "Add a new pizza to the menu"
      attribute :name
      attribute :description
    end

    command "AddTopping" do
      role "Chef"
      reference_to Pizza
      attribute :name
      attribute :amount, Integer
      given("max 10 toppings") { toppings.size < 10 }
      then_set :toppings, append: { name: :name, amount: :amount }
    end

    query "ByDescription" do |desc|
      where(description: desc)
    end
  end

  aggregate "Order" do
    attribute :customer_name
    attribute :items, OrderItem
    reference_to Pizza
    value_object "OrderItem" do
      attribute :quantity, Integer
      invariant("quantity must be positive") { quantity > 0 }
    end
    attribute :status, default: "pending" do
      transition "CancelOrder" => "cancelled"
    end
    command "PlaceOrder" do
      role "Customer"
      reference_to Pizza
      attribute :customer_name
      attribute :quantity, Integer
    end
    command "CancelOrder" do
      role "Customer"
      reference_to Order
    end
    query "Pending" do
      where(status: "pending")
    end
  end
end
```

### A.2 `pizzas.hecksagon`

From `examples/pizzas/hecks/pizzas.hecksagon`:

```ruby
Hecks.hecksagon "Pizzas" do
  capabilities :crud
end
```

The `:crud` capability expands at parse time to memory adapters for every aggregate, plus standard HTTP routes. An equivalent explicit form would declare `adapter :memory` and one `gate` per aggregate.

### A.3 `pizzas.fixtures` (illustrative)

No `.fixtures` ships with Pizzas in the repository today; an illustrative sibling would read:

```ruby
Hecks.fixtures "Pizzas" do
  seeds :Pizza do
    row name: "Margherita", description: "Classic"
    row name: "Pepperoni",  description: "Spicy"
  end

  seeds :Topping do
    row name: "Mozzarella", amount: 1
    row name: "Basil",      amount: 2
  end
end
```

### A.4 `pizzas.behaviors` (illustrative)

An illustrative sibling would read:

```ruby
Hecks.behaviors "Pizzas" do
  tests "CreatePizza emits CreatedPizza" do
    setup {}
    input  CreatePizza: { name: "Margherita", description: "Classic" }
    expect emits: [:CreatedPizza]
  end

  tests "PlaceOrder then CancelOrder cascades to cancelled" do
    setup  CreatePizza: { name: "Margherita", description: "Classic" }
    input  PlaceOrder:  { customer_name: "Ada", quantity: 1 }
    expect emits: [:PlacedOrder]
  end
end
```

### A.5 `pizzas.world` (illustrative)

```ruby
Hecks.world "Pizzas" do
  heki dir: "./tmp/pizzas.heki"
  http port: 4567
end
```

### A.6 Running

The bundled run script is `examples/pizzas/pizzas.rb`. It calls `Hecks.boot(__dir__)`, subscribes to `CreatedPizza`, `AddedTopping`, `PlacedOrder`, and `CanceledOrder`, and then exercises the command bus through the generated aggregate classes (`Pizza.create`, `pizza.toppings.create`, `Order.place`, `Order.cancel`). The event log is printed at the end, demonstrating event sourcing.

---

## Appendix B — The Sixteen Contracts

**Table B.1 — The sixteen contracts in `lib/hecks/conventions/`.**

| # | Name                  | File                                               | LoC | Purpose                                                     | Primary consumers                        |
|---|-----------------------|----------------------------------------------------|-----|-------------------------------------------------------------|-------------------------------------------|
| 1 | AggregateContract     | `lib/hecks/conventions/aggregate_contract.rb`      | 169 | Field classification, validations, enums, self-ref detection, create/update partitioning, direct-action detection | Every aggregate generator                 |
| 2 | CommandContract       | `lib/hecks/conventions/command_contract.rb`        | 73  | Command method-name derivation, aggregate-suffix matching   | Command generators; dispatch              |
| 3 | CsrfContract          | `lib/hecks/conventions/csrf_contract.rb`           | 43  | CSRF token handling for generated forms                     | Form template generators                  |
| 4 | DispatchContract      | `lib/hecks/conventions/dispatch_contract.rb`       | 62  | Command-bus dispatch routing                                | Runtime; Go server generator              |
| 5 | DisplayContract       | `lib/hecks/conventions/display_contract.rb`        | 192 | Cell expressions, lifecycle labels, reference display fields | View/template generators                  |
| 6 | EventContract         | `lib/hecks/conventions/event_contract.rb`          | 45  | Event interface, `aggregate_id`, `occurred_at`              | Event generators both languages           |
| 7 | EventLogContract      | `lib/hecks/conventions/event_log_contract.rb`      | 55  | JSON shape for `GET /_events` (identical Ruby/Go)           | Servers; event-bus clients                |
| 8 | ExtensionContract     | `lib/hecks/conventions/extension_contract.rb`      | 131 | Extension kind classification and boot order                | Runtime boot                              |
| 9 | FormParsingContract   | `lib/hecks/conventions/form_parsing_contract.rb`   | 77  | Go type → HTML input spec, parse lines, Ruby coerce         | Form template generators                  |
| 10 | MigrationContract    | `lib/hecks/conventions/migration_contract.rb`      | 83  | Round-trip serialisation for domain snapshots               | Migrations                                |
| 11 | NamingContract       | `lib/hecks/conventions/naming_contract.rb`         | 125 | Naming convention enforcement                               | All generators                            |
| 12 | NamingHelpers (mixin)| `lib/hecks/conventions/naming_helpers.rb`          | 88  | Singularize/pluralize/humanize helpers                      | All generators                            |
| 13 | RouteContract        | `lib/hecks/conventions/route_contract.rb`          | 25  | URL patterns (`form_path`, `submit_path`) for commands      | Routers; server generators                |
| 14 | TypeContract         | `lib/hecks/conventions/type_contract.rb`           | 115 | Single type registry (Go, SQL, JSON, OpenAPI, TypeScript)   | All generators                            |
| 15 | UILabelContract      | `lib/hecks/conventions/ui_label_contract.rb`       | 49  | PascalCase splitting, pluralization, strips `_id` suffix    | View/template generators                  |
| 16 | ViewContract         | `lib/hecks/conventions/view_contract.rb`           | 251 | Template data shapes (layout/home/index/show/form/config), Go struct generation | View/template generators  |

Total: 1,583 lines.

---

## Appendix C — Abridged Grammars

The grammars below are EBNF-style skeletons covering the outer block and top-level keywords for each DSL. Terminals in quotes; non-terminals italicised by context. The authoritative parsers are cited per section.

### C.1 `.bluebook`

Authoritative parsers: Rust `hecks_life/src/parser.rs` + `hecks_life/src/ir.rs`; Ruby `lib/hecks/dsl/` via `Hecks.bluebook`.

```
Bluebook      ::= "Hecks.bluebook" String "do" BluebookBody "end"
BluebookBody  ::= { VisionLine | CoreLine | CategoryLine | AggregateBlock | PolicyBlock }
VisionLine    ::= "vision" String
CoreLine      ::= "core"
CategoryLine  ::= "category" String
AggregateBlock ::= "aggregate" String [","] String? "do" AggregateBody "end"
AggregateBody ::= { AttributeLine | ValueObjectBlock | CommandBlock | QueryBlock
                  | ReferenceLine | LifecycleBlock | InvariantBlock }
AttributeLine ::= "attribute" Symbol [ "," Type ] [ "," KeyValues ] [ "do" TransitionBody "end" ]
CommandBlock  ::= "command" String "do" CommandBody "end"
CommandBody   ::= { RoleLine | GoalLine | AttributeLine | ReferenceLine | GivenLine | ThenLine }
ValueObjectBlock ::= "value_object" String "do" { AttributeLine | InvariantBlock } "end"
QueryBlock    ::= "query" String [ BlockArgs ] "do" Expr "end"
```

### C.2 `.hecksagon`

Authoritative parsers: Rust `hecks_life/src/hecksagon_parser.rs` + `hecksagon_ir.rs`; Ruby `lib/hecksagon/dsl/`.

```
Hecksagon   ::= "Hecks.hecksagon" String "do" HecksagonBody "end"
HecksagonBody ::= { AdapterLine | GateBlock | SubscribeBlock | CapabilitiesLine }
AdapterLine ::= "adapter" Symbol [ "," KeyValues ]
GateBlock   ::= "gate" String "," Symbol [ "do" GateBody "end" ]
GateBody    ::= { "allow" Symbol }
SubscribeBlock ::= "subscribe" Symbol "do" ... "end"
CapabilitiesLine ::= "capabilities" Symbol { "," Symbol }
```

### C.3 `.fixtures`

Authoritative parsers: Rust `hecks_life/src/fixtures_parser.rs` + `fixtures_ir.rs`; Ruby `Hecks.fixtures`.

```
Fixtures   ::= "Hecks.fixtures" String "do" FixturesBody "end"
FixturesBody ::= { SeedsBlock | CatalogBlock }
SeedsBlock ::= "seeds" Symbol "do" { RowLine } "end"
RowLine    ::= "row" KeyValues
CatalogBlock ::= "catalog" Symbol "do" { AttributeLine } "end"
```

### C.4 `.behaviors`

Authoritative parsers: Rust `hecks_life/src/behaviors_parser.rs` + `behaviors_ir.rs`; Ruby `Hecks.behaviors`.

```
Behaviors   ::= "Hecks.behaviors" String "do" { TestBlock } "end"
TestBlock   ::= "tests" String "do" TestBody "end"
TestBody    ::= SetupLine InputLine ExpectLine
SetupLine   ::= "setup" ( Block | CommandAssertions )
InputLine   ::= "input"  CommandAssertions
ExpectLine  ::= "expect" ExpectBody
ExpectBody  ::= "emits:" "[" Symbol { "," Symbol } "]" [ "," KeyValues ]
```

### C.5 `.world`

Authoritative parsers: Rust `hecks_life/src/world_ir.rs` (parser in same file); Ruby `lib/hecksagon/dsl/world_builder.rb` via `Hecks.world`.

```
World    ::= "Hecks.world" String "do" WorldBody "end"
WorldBody ::= { ExtensionLine }
ExtensionLine ::= Identifier KeyValues        # e.g. "heki dir: './tmp/x.heki'"
                | Identifier Symbol KeyValues # e.g. "ollama model: :llama3 ..."
```

---

*End of paper.*
