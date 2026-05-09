# cadence-primitive branch — debrief

Off `dream-study`. Adds the bluebook `cadence` keyword to retire imperative
while-true-sleep-1-dispatch loops in shells. Phase 1 Ruby-only landed ;
the Rust side did NOT — pulling on it surfaced one level deeper that
parser.rs is itself imperative drift.

## What's here

**Commit `5c820297`** — `cadence` Ruby DSL keyword + IR + builder :

  - `ruby/hecks/bluebook_model/behavior/cadence.rb` — IR node
  - `ruby/hecks/dsl/cadence_builder.rb` — DSL builder
  - `ruby/hecks/dsl/bluebook_builder.rb` — `def cadence` wiring + threading
  - `ruby/hecks/bluebook_model/structure/domain.rb` — `cadences` attr
  - `ruby/hecks/bluebook_model/behavior.rb` + `autoloads.rb` — autoloads

DSL surface :

```ruby
cadence "BodyTick" do
  every "1s"
  dispatch "Consciousness.ElapsePhase", name: "consciousness"
  dispatch "Tick.MindstreamTick",       name: "tick"
end
```

Smoke test : the BodyTick example parses, captures both dispatches with
their kwargs, validates bad interval + unqualified command. 26/26
existing process_manager specs still green.

## What's NOT here — and why

Started writing the Rust side (parser.rs keyword dispatch + ir.rs
Cadence struct + parse_blocks.rs parse_cadence). Three edits in,
Chris's reflex — *parser.rs could be bluebook* — landed and was right.

Adding cadence handling to parser.rs is the textbook imperative
drift : a routing table dressed as code. Every new bluebook keyword
today = a Rust diff in parser.rs. The structural answer is a
`block_grammar` primitive that declares the routing table itself :

```ruby
block_grammar "Bluebook" do
  block "aggregate",        parser: :parse_aggregate
  block "policy",           parser: :parse_policy
  block "process_manager",  parser: :parse_process_manager
  block "cadence",          parser: :parse_cadence
  ...
end
```

Rust parser.rs becomes a thin loop walking that grammar — adding a
new keyword is a one-line bluebook edit, not a Rust patch.

Reverted the in-flight Rust additions ; the Ruby Phase 1 stays
because the DSL surface is real domain content, not parser-table
glue. When `block_grammar` lands as its own branch, Rust-side cadence
parsing falls out for free as one row in the grammar.

## The recursion landscape (one more level visible)

Each Bluebook-First reflex catch across the day points at a follow-on
primitive. The list is now six :

| Primitive             | Replaces (imperative drift)             | Status |
|-----------------------|------------------------------------------|--------|
| `runtime_engine`      | pm_engine.rs / policy_engine.rs / etc.   | filed  |
| `storage_policy`      | heki.rs audit policy half                | filed  |
| `block_grammar`       | parser.rs keyword routing + parse_blocks.rs grammar (NEW today, surfaced via cadence Phase 1b) | filed  |
| `cadence`             | mindstream.sh while-true-sleep loop      | Phase 1 in (Ruby) ; Rust side waits on `block_grammar` |
| `Statusline.Render`   | run_statusline.rs hardcoded format strings | prep done (1d887167) |
| (latent) `:llm` adapter | rem_branch / nrem_branch / mint_musing shells | named in plan |

The pattern : every level can be lifted ; each level still has its
interpreter at the level below ; the floor (L0) is bytes + machine
code. Tonight's work plants L_a at process_manager + cadence (Ruby DSL +
runtime). The L_b lifts (`runtime_engine`, `block_grammar`,
`storage_policy`) are each their own branch.

## Branch state

- Off `dream-study`
- One commit (`5c820297`)
- Working tree clean ; uncommitted Rust additions reverted via `git restore`
- Phase 1b (Rust side) blocked on `block_grammar` primitive landing first
- Phase 2 (runtime tick loop reading cadence IR) waits on Phase 1b
- Phase 3 (retire mindstream.sh entirely) waits on Phase 2

The cadence DSL is a *promesse* — declarative on the Ruby side, waiting
for the Rust side to be lifted out of imperative drift before it can
parse + execute production-side. Until then the legacy `hecks-life loop`
+ mindstream.sh do the cadence work directly.
