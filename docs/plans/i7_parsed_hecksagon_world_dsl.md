# i7 — First-class parsed DSL for `.hecksagon` and `.world`

Source: inbox `i7` + plan by Agent a7dcd5eb on 2026-04-22.

`.hecksagon` and `.world` files are currently Ruby source executed via
`Kernel.load`. That violates the five-DSL principle (parity across
`.bluebook`, `.hecksagon`, `.fixtures`, `.behaviors`, `.world`) and means
the runtime happily evaluates arbitrary Ruby from these files. This
plan closes the gap.

## §1 — Current state (2026-04-22)

**Already shipped:**
- PR #245 — rename `.hec` → `.hecksagon` / `.world`
- Commit 9b0121a4 — Rust parser + IR: `hecksagon_parser.rs` (189 LoC),
  `hecksagon_ir.rs` (116 LoC), `hecksagon_helpers.rs` (145 LoC), tests
- PRs #250/#251 — `adapter :shell` DSL + HecksagonBuilder wiring

**Still open:**
- Ruby: `Hecks.hecksagon "Name" do … end` evaluated via `Kernel.load`
  (`lib/hecks/runtime/boot.rb:42`); builder at `lib/hecksagon/dsl/hecksagon_builder.rb`
- Ruby: `Hecks.world "Name" do … end` same (`boot.rb:43`)
- Rust: **no `world_parser.rs` / `world_ir.rs` exists.** `.world` is
  read ad-hoc by two line-scanners in `hecks_life/src/main.rs`
  (`find_world_heki_dir` L1219-1239, `find_world_ollama_config` L1157-1186)
- No parity contract for either file type

**Consumer audit (verified):**
- 17 `.hecksagon` files: 10 under `hecks_conception/`, 4 under `examples/`, 3 under `lib/hecks/…/appeal`
- 8 `.world` files: 5 under `hecks_conception/`, 3 under `lib/hecks/…/appeal`
- Two `Kernel.load` sites in `boot.rb:42,43`. No other callers.
- **Ruby-specific construct found in exactly 1 file**: `hecks_conception/miette.hecksagon:20`
  uses `File.join(__dir__, "information")` for `persistence :information, dir:`.
  Every other file is plain DSL. This is the biggest portability risk (§8).

## §2 — Ruby hecksagon DSL — builder approach

**Decision: option (b) — keep instance-eval, add a source allow-list guard.**

Rationale: Ruby `HecksagonBuilder` already captures exactly the IR
shape the Rust parser emits. The missing piece is a **gate** against
arbitrary Ruby. The antibody value (no arbitrary execution) comes from
gating, not parser substitution. `.bluebook` uses this same play.

### Shape of new Ruby loader (`lib/hecksagon/loader.rb`, ~80 LoC)

```ruby
module Hecksagon
  module Loader
    def self.load(path)
      source = File.read(path)
      validate_hecksagon_source!(source, path)
      Hecks.module_eval(source, path, 1)
    end

    def self.validate_hecksagon_source!(source, path)
      source.each_line.with_index(1) do |line, ln|
        stripped = strip_comment(line).strip
        next if stripped.empty? || allowed_line?(stripped)
        raise UnsafeHecksagonError,
          "#{path}:#{ln}: disallowed construct — `#{stripped}`"
      end
    end

    ALLOWED = %w[Hecks.hecksagon adapter gate allow capabilities concerns
                 driving driven subscribe annotate tenancy context_map
                 port extension persistence aggregate end].freeze
  end
end
```

Allow-list is the parity-tested surface; anything outside fails.

Then `boot.rb:42,43` changes from `Kernel.load(f)` to
`Hecksagon::Loader.load(f)` / `.load_world(f)`.

## §3 — `.world` DSL shape

Two families exist in-tree:

**Family A** — runtime/extension config (`miette.world`, `hecks_appeal.world`):
```ruby
Hecks.world "Miette" do
  heki   do; dir "information" end
  ollama do; model "bluebook-architect"; url "http://localhost:11434" end
end
```

**Family B** — meta/strategic descriptors (`nursery/*.world`):
```ruby
Hecks.world "DomainConception" do
  purpose "…"
  vision  "…"
  concern "CompletenessAtBirth" do; description "…" end
end
```

Current `WorldBuilder` handles A only; B files would crash today. This
plan unifies them.

### IR

```
World {
  name: String
  purpose, vision, audience: Option<String>
  concerns: Vec<{name, description}>
  configs:  Map<extension_name, Map<key, value>>
}
```

- `lib/hecksagon/structure/world.rb` gains 4 attributes + `to_h`
- `lib/hecksagon/dsl/world_builder.rb` gains `purpose`, `vision`,
  `audience`, `concern(name) { description "…" }`
- Rust: NEW `hecks_life/src/world_parser.rs` + `world_ir.rs`

### Grammar

```
file       := 'Hecks.world' STRING 'do' stmt* 'end'
stmt       := scalar | extension_block | concern_block
scalar     := SCALAR_KEY STRING
extension_block := IDENT 'do' kv* 'end'
concern_block   := 'concern' STRING 'do' kv* 'end'
kv         := IDENT (STRING | INT | FLOAT | BOOL | ARRAY)
```

No method calls, no interpolation, no `ENV[]`, no `File.join`.

## §4 — Parity contracts

### New test files
- `spec/parity/hecksagon_parity_test.rb` — globs every `.hecksagon`,
  Ruby IR via `Loader.load` → JSON; Rust IR via `hecks-life dump-hecksagon` → JSON; diff.
- `spec/parity/world_parity_test.rb` — same for `.world`.
- `spec/parity/hecksagon_known_drift.txt` / `world_known_drift.txt` — start empty.

### New Rust dump subcommands
- `hecks-life dump-hecksagon <path>` — calls `hecksagon_parser::parse`,
  emits canonical JSON matching Ruby side
- `hecks-life dump-world <path>` — same for `.world`

### CI gate
- `bin/antibody-check`: add `ruby spec/parity/hecksagon_parity_test.rb`
  and `ruby spec/parity/world_parity_test.rb`. Drift exits 1.
- CI workflows mirror the same.

## §5 — Retirement of `Kernel.load`

Once parity is green on every file:
1. Swap `boot.rb:42,43` from `Kernel.load(f)` to `Hecksagon::Loader.load(f)` etc.
2. Delete ad-hoc `.world` scanners in `main.rs` (`find_world_heki_dir`,
   `find_world_ollama_config`); replace with `world_parser::parse`.
3. **Antibody promotion**: refuse any new `Kernel.load` call site against
   `*.hecksagon` / `*.world` / `*.bluebook` / `*.behaviors` / `*.fixtures`.
   No exemption. This is the important antibody moment.
4. Document in `docs/narrative.md`: "5/5 DSLs parsed, not executed."

## §6 — Consumer audit

### Files changed

**Ruby:** `boot.rb` (2 call-site swaps), `lib/hecksagon/loader.rb` NEW
(~80 LoC), `lib/hecksagon.rb` autoload, `world_builder.rb` (~30 LoC),
`world.rb` (~15 LoC), `spec/parity/canonical_ir.rb` (~40 LoC).

**Rust:** `world_parser.rs` NEW (~180 LoC, mirror of hecksagon_parser),
`world_ir.rs` NEW (~80 LoC), `main.rs` (+30 dump subcommands, -80 ad-hoc
scanners), `lib.rs` module exports.

**Tests:** `world_parser_test.rs` NEW, parity test files NEW.

**Antibody + CI:** `bin/antibody-check` adds Kernel.load rule + parity
runs; CI workflows mirror.

**Totals:** ~500 LoC added, ~100 LoC removed. Net: +400 LoC, −2 sites
of arbitrary Ruby execution.

## §7 — Commit sequence (7 commits)

| # | Commit | Scope |
|---|---|---|
| 1 | world: Rust parser + IR | New `world_parser.rs` + `world_ir.rs` + test |
| 2 | main.rs: route .world through world_parser | Delete ad-hoc scanners; add `dump-world` |
| 3 | main.rs: add dump-hecksagon subcommand | Emit JSON matching Ruby IR |
| 4 | world: Ruby builder gains purpose/vision/audience/concern | Extend WorldBuilder + Structure::World |
| 5 | parity: hecksagon + world parity tests | New spec files + canonical helpers |
| 6 | hecksagon: Ruby allow-list loader | `Hecksagon::Loader` + boot swap + antibody rule |
| 7 | docs: DSL parity milestone — 5/5 parsed | `docs/narrative.md` update |

Commits 1–4 parallelizable. 5 depends on all. 6 is the antibody moment.

## §8 — Risks

### R1 (biggest) — `hecks_conception/miette.hecksagon:20`

```ruby
persistence :information, dir: File.join(__dir__, "information")
```

The only live Ruby code in any `.hecksagon`/`.world` file. Allow-list
loader rejects it; Rust parser has no `__dir__`.

**Picked: rewrite to `dir: "information"`**, let runtime resolve
relative to the `.hecksagon`'s own directory. Matches how `.world`'s
`heki do; dir "information" end` already works (see `find_world_heki_dir`
which prepends parent). Smallest change, best long-term.

### R2 — Family B `.world` files crash today

Four nursery `.world` files use top-level `purpose "..."` with no block,
which hits `super` in `method_missing`. Nothing loads them today.
Commit 4 makes them load.

### R3 — Two `.hecksagon` under `lib/hecks/appeal` use `annotate`,
`capabilities`, `subscribe` combinations the Rust parser doesn't fully
model. List in `hecksagon_known_drift.txt` until Rust IR grows the
missing fields.

### R4 — Pre-commit speed: +2s on cold cargo build. Within budget.

## §9 — Sequencing

```
C1 (world parser+IR) ──┐
C2 (route .world)    ──┤
C3 (dump-hecksagon)  ──┼── C5 (parity tests) ── C6 (Ruby loader + boot swap) ── C7 (docs)
C4 (Ruby WorldBuilder)─┘
```

## Critical files

- `lib/hecks/runtime/boot.rb`
- `lib/hecksagon/dsl/hecksagon_builder.rb`
- `lib/hecksagon/dsl/world_builder.rb`
- `hecks_life/src/main.rs`
- `hecks_life/src/hecksagon_parser.rs`
- `hecks_conception/miette.hecksagon` (R1 fix)
