---
ref: i739
status: design
priority: high
posted_at: 2026-05-23
related: i246, i255, i494, i130, i128, i132
subsumes: i246, i130
---

# i739 — f4 meta-bluebook DSL design

Design-only. No kernel edits. This document locks the API for three
constructs driven by concrete current work, then phases the implementation.
Reviewers: read "Vocab note" before anything else.

---

## Vocab note — i255 overrides the task's examples

The task examples use `invariant` keyword. i255 (the foundational vocab
card, already queued, cited by i246 and i130) explicitly retires
`invariant` and locks `rule` for "aggregate-level fact that must always
hold." This design uses `rule` throughout. The distinction:

  - `rule`       — aggregate invariant; must always hold; rolls back dispatch
  - `given`      — command applicability gate; already a DSL primitive
  - `expects`    — command precondition (i252, deferred)
  - `guarantees` — command postcondition (i252, deferred)

---

## The three driver constructs

### Driver 1 — Voice "one mouth" invariant (rule construct)

**Precondition to state.** voice.bluebook today has NO Utterance entity.
The existing aggregates are PhraseCache, LatencyEvent, LatencyTelemetry
(cache directory config, per-utterance audit log, rolling-5 telemetry).
The "at most one Utterance in speaking state" constraint can only land
once an Utterance entity exists. The design specifies BOTH the Utterance
entity shape AND the rule construct, with Utterance as the canonical
driver.

**Required Utterance entity shape** (to be added to voice.bluebook):
```ruby
aggregate "Utterance", "One speech act — queued, speaking, or spoken" do
  identified_by :id

  attribute :id,       Id
  attribute :text,     Text
  attribute :state,    State, default: "queued"

  lifecycle :state, default: "queued" do
    transition "Speak"  => "speaking",  from: "queued"
    transition "Finish" => "spoken",    from: "speaking"
    transition "Cancel" => "cancelled", from: ["queued", "speaking"]
  end

  rule "one mouth" do
    at_most 1, where: { state: "speaking" }
  end
end
```

**Locked API — the `rule` construct:**
```ruby
# Aggregate-level invariant. Checked after apply_mutations,
# before emit_event + persist. Violation rolls back dispatch.

rule "name" do
  at_most <n>, where: { <field>: <value> }     # cardinality form
  at_least <n>, where: { <field>: <value> }     # cardinality form (lower bound)
  requires { <field> <op> <value> }             # attribute predicate form
  when_present :<attr>                          # gate: only check if attr is set
end
```

Two predicate forms, NOT arbitrary Ruby blocks:

- **Cardinality form** (`at_most` / `at_least`): integer cap on records
  matching a where-clause. `where:` reuses the existing `WhereClause` IR
  shape (field/op/value pairs) — `{ state: "speaking" }` parses identically
  to how query `where state: "speaking"` does today. No new parser surface.

- **Attribute predicate form** (`requires { ... }`): single boolean
  expression over the aggregate's attribute names. The parser ALREADY
  handles this in `consume_rule_block` and errors on multi-statement bodies
  (i259). Phase 1 lifts `consume_rule_block` from discard to IR emission —
  the expression string is captured and stored in `RulePredicate::Expression
  { expr }`, but the Rust runtime does NOT evaluate it in Phase 1. Runtime
  evaluation of arbitrary boolean expressions requires a Ruby AST or an
  expression interpreter; that is Phase 1.5 (a sub-design of its own). In
  Phase 1 only `at_most` / `at_least` cardinality forms and `when_present`
  gates are runnable. A `requires { }` rule is parsed and stored but the
  runtime skips it with a log-level warning until Phase 1.5 lands.

- **Gate** (`when_present :<attr>`): skip the check when the named
  attribute is nil/empty. Parsed as a simple symbol extraction on the
  `when_present` line.

**Why not arbitrary Ruby blocks?** `consume_rule_block` (parse_blocks.rs
line 1544) already rejects multi-statement bodies with a structured panic.
Arbitrary blocks would require a Ruby AST and break parity. WhereClause
reuse and the single-expression requires form sidestep both problems.

---

### Driver 2 — Fibroblast `for_each` repair loop (process_manager construct)

**Current state.** fibroblast.bluebook today is an `aggregate "Fibroblast"`
plus a `policy "RunSweepOnSweepRan"` that fires `Primitive::Process.Spawn`
with `cmd: "bash bin/fibroblast_sweep.sh"`. The shell script internally
loops: `for_each open_healing -> SelectStrategy/Heal/RecordOutcome`. The
loop is opaque to the bluebook.

**What's missing.** The DSL has no way to express "for each record returned
by a query, dispatch a command." The `ForEachSpec` struct already exists in
ir.rs (line 258) and is parsed from `dispatch "X", for_each: { from:
"Agg.query" }` inside PM `on`-handler bodies. What's missing is:

1. A top-level `process_manager` form for the Fibroblast that isn't an
   aggregate (it IS process-shaped, but was filed as an aggregate because
   the PM first-class form didn't exist yet).
2. A standalone `for_each` clause that works both inside PM handlers AND
   as a policy-level iteration, not just nested in a `dispatch` line.

**Before** (today):
```ruby
aggregate "Fibroblast", "..." do
  ...
  command "Sweep" do ...  emits "SweepRan" end
end

policy "RunSweepOnSweepRan" do
  on "SweepRan"
  trigger "Primitive::Process.Spawn"
  with "cmd", "bash bin/fibroblast_sweep.sh"
  with "result_into", "Cascade.RecordResult"
end
# The shell script handles the for_each loop internally
```

**After** (locked API):
```ruby
process_manager "FibroblastSweep" do
  correlates_by :signal_id
  starts_on "SweepRan"

  on "SweepRan", transition: { waiting: :running } do
    for_each "Fibroblast.open_healings" do
      dispatch "Fibroblast.SelectStrategy", with: { signal_id: from_iter(:signal_id) }
      dispatch "Fibroblast.Heal",           with: { signal_id: from_iter(:signal_id) }
      dispatch "Fibroblast.RecordOutcome",  with: { signal_id: from_iter(:signal_id) }
    end
  end
end
```

**Locked API — `for_each` block inside PM `on`-handler:**
```ruby
for_each "<Aggregate.query_name>" do
  dispatch "<Aggregate.Command>", with: { <key>: from_iter(:<field>) }
  ...
end
```

This extends the EXISTING `parse_pm_handler` / `parse_dispatch_statement`
path. `ForEachSpec` already carries `source_aggregate` + `query_name`. The
new part: a `for_each "X.y" do ... end` BLOCK inside an on-handler that
wraps multiple dispatch statements (today `for_each:` is a kwarg on a single
dispatch line). The parser needs to recognize the block form and attach the
`ForEachSpec` to ALL contained dispatches, not just one.

**Note on `Primitive::File.Edit`.** The sitemap-edit fibroblast strategy
needs a file-edit primitive analogous to `Process.Spawn`. This is a NEW
aggregate in the Primitive bluebook — it is NOT a meta-bluebook DSL
construct and is OUT OF SCOPE for f4. File as a follow-up against
`aggregates/framework/primitive/primitive.bluebook`.

---

### Driver 3 — Story `blocked_by` (typed reference list construct)

**Current state.** `Reference { name, target, domain }` in ir.rs is
singular: `reference_to(Story)` generates a single named cross-aggregate
ref. Story.bluebook uses `attribute :subsumes, list_of(CardRef)` for a VO
list — but CardRef is a plain string VO, not a typed cross-aggregate edge.
A `blocked_by` relationship ("f16 is blocked by f4") is a LIST of typed
references to the same aggregate (Story → [Story, Story, ...]).

**Locked API — `references_to` (typed reference list):**
```ruby
aggregate "Story", "..." do
  ...
  references_to(Story, as: :blocked_by)    # list-of cross-agg refs, same type
end
```

This generates:
- IR: `Aggregate.reference_lists: Vec<ReferenceList>` where
  `ReferenceList { name, target, domain }` mirrors `Reference` but implies
  `list: true`.
- Dispatch: `blocked_by` becomes a list attribute on commands that mutate
  it, e.g.:
```ruby
command "Block" do
  reference_to(Story)                 # the story being blocked
  references_to(Story, as: :blocked_by)  # the blocking stories (list)
  then_set :blocked_by, append: :blocked_by
  emits "StoryBlocked"
end
```

**Why not reuse `list_of(CardRef)` VO pattern?** CardRef is an opaque
string VO — it has no dispatch-time validation, no cross-aggregate
resolution, no FQN routing. `references_to(Story)` teaches the runtime to
resolve the reference as a typed `Story` record at dispatch time, the same
way singular `reference_to(Story)` does. The FQN resolver and the behaviors
`reference_to` sugar both need typed edges to validate them; VO strings
bypass that gate.

**Minimal syntax alternative (if parser budget is tight):**
```ruby
attribute :blocked_by, list_of(Ref)    # fallback VO list form
```
This already works via existing parser. Use it as a temporary placeholder
until `references_to` lands. Lock the semantic target as `references_to`
but allow the VO placeholder for the story.bluebook immediately.

---

## Parser grain — what's hard and what's easy

### Easy (lift existing structure)

| Construct | What exists today | What the first slice does |
|---|---|---|
| `rule` | `consume_rule_block` parses + DISCARDS (parse_blocks.rs:1544) | Stop discarding; emit `Rule { name, gates, predicate }` IR |
| `for_each` block in PM | `ForEachSpec { source_aggregate, query_name }` in ir.rs:258; parsed from kwarg form `for_each: { from: "Agg.q" }` | Recognize block form `for_each "X.y" do ... end` and attach spec to all enclosed dispatches |
| `references_to` | `Reference { name, target, domain }` in ir.rs:498 | Add `ReferenceList` struct (same fields + list flag); add `references_to` parse arm alongside `reference_to` |

### Hard (new parser ground)

| Construct | Difficulty | Reason |
|---|---|---|
| `at_most`/`at_least` cardinality form | Medium | New keyword inside rule block; needs integer + WhereClause extraction |
| `requires { ... }` emit (vs discard) | Low | Parser already validates; just push Rule into `agg.rules` |
| `for_each` block form (multi-dispatch wrap) | Medium | Block depth tracking inside an on-handler that already tracks depth; risk of off-by-one |

### The grain problem with `for_each` block

Today `parse_pm_handler` reads one `dispatch "X", for_each: { from: "Y" }`
kwarg per dispatch line. The block form `for_each "X.y" do ... end` wraps
multiple dispatch lines and needs the parser to:
1. Detect `for_each` as a block opener (not a kwarg).
2. Walk its body collecting dispatch statements (reusing `parse_dispatch_statement`).
3. Inject the parsed `ForEachSpec` onto each collected `DispatchSpec`.

This is a depth-tracker inside a depth-tracker (the PM on-handler already
tracks indent-matched `end`). The safe implementation: parse the
`for_each` block as a nested unit, collect all dispatches, then stamp each
with the spec. No recursion needed; the pattern is identical to how
`parse_cadence` collects dispatches in a flat loop.

---

## Locked API summary (complete surface, one place)

### 1. `rule` (aggregate-level invariant)

```ruby
# Inside aggregate "Foo" do ... end

rule "name" do
  # One or more of:
  when_present :<attr>                          # gate
  at_most <n>, where: { <field>: <value> }      # cardinality upper bound
  at_least <n>, where: { <field>: <value> }     # cardinality lower bound
  requires { <simple_bool_expr> }               # attribute predicate
end
```

IR shape:
```rust
pub struct Rule {
    pub name: String,
    pub gates: Vec<RuleGate>,
    pub predicate: RulePredicate,
}

pub enum RuleGate {
    WhenPresent { attr: String },
}

pub enum RulePredicate {
    Cardinality { op: CardinalityOp, count: usize, wheres: Vec<WhereClause> },
    Expression { expr: String },   // single-expression, validated by consume_rule_block
}

pub enum CardinalityOp { AtMost, AtLeast }
```

`Aggregate` gains: `pub rules: Vec<Rule>` (empty for existing aggregates —
backward compatible, zero serialization drift until rules appear).

### 2. `for_each` block in PM `on`-handler

```ruby
# Inside process_manager "X" do  on "E", transition: { a: :b } do
for_each "<Aggregate.query_name>" do
  dispatch "<Aggregate.Command>", with: { <key>: from_iter(:<field>) }
end
# end (closes on handler)   end (closes pm)
```

IR shape: no new structs. `ForEachSpec` already exists. The block form
adds `for_each_block: Option<ForEachSpec>` to `ProcessManagerHandler`
(separate from the per-dispatch `for_each` kwarg). All dispatch statements
inside the block inherit the spec. The kwarg form on a single dispatch
remains valid for single-dispatch sweeps.

### 3. `references_to` (typed reference list)

```ruby
# Inside aggregate "Foo" do ... end or inside command "Bar" do ... end
references_to(<AggregateName>, as: :<name>)    # as: is REQUIRED
```

`as:` is required — there is no default name. Auto-pluralization
(`to_snake_case(target) + "s"`) is excluded: `Story` → `storys` is wrong and
the domain shape is too load-bearing to guess. Every call site names the list
explicitly.

The `as:` kwarg is mandatory at every call site.

IR shape:
```rust
pub struct ReferenceList {
    pub name: String,    // e.g. "blocked_by" — always explicit, never derived
    pub target: String,  // e.g. "Story"
    pub domain: Option<String>,
}
// Added to Aggregate: pub reference_lists: Vec<ReferenceList>
// Added to Command:   pub reference_lists: Vec<ReferenceList>
```

---

## Minimal first slice — `rule` on Utterance

Build order rationale: voice "one mouth" (`rule` construct) is the
highest-pull because:
- The parser already has `consume_rule_block` — the first slice is
  "start emitting IR" not "build a parser."
- The runtime hook location is pinned (i246: after `apply_mutations`,
  before `emit_event`).
- The behaviors matcher (`expect_rule_failure :name`) is the only new
  test surface; everything else is lifted from existing givens machinery.
- Utterance entity adds domain value independently (voice.bluebook needs it).

The `for_each` block form and `references_to` each require more new parser
ground and should follow after `rule` is green.

**First-slice scope:**
1. Add `Utterance` aggregate to voice.bluebook (entity with lifecycle +
   queued/speaking/spoken states).
2. Add `rule "one mouth" do at_most 1, where: { state: "speaking" } end`
   to Utterance.
3. IR: add `Rule`, `RuleGate`, `RulePredicate`, `CardinalityOp` structs;
   add `rules: Vec<Rule>` to `Aggregate`.
4. Parser: in `parse_aggregate`, replace `consume_rule_block` call with
   `parse_rule_block` that emits IR. New `parse_rule_block` reads `rule
   "name" do ... end`, walks body for `when_present`, `at_most`/`at_least`,
   `requires { }` lines.
5. Runtime: `command_dispatch.rs` — after `apply_mutations`, before
   `emit_event`, call `check_aggregate_rules(agg, domain)`. The cardinality
   check queries `repository.all(agg_name)` filtered by the WhereClause and
   compares count to the cap.
6. Ruby parity: `BluebookModel::Rule` struct + `canonical_ir.rb` dump +
   `parity/canonical_ir.rb` `dump_aggregate` extension + parity goldens
   updated.
7. Behaviors: `expect_rule_failure "name"` matcher.

---

## Phased implementation plan

### Phase 1 — `rule` construct (first slice)

**Step 1.1: IR** (storehouse/src/ir.rs)
- Add `Rule`, `RuleGate`, `RulePredicate`, `CardinalityOp` structs.
- Add `pub rules: Vec<Rule>` to `Aggregate` (zero impact on existing
  aggregates; `dump.rs` emits empty list just like `entities` does).

**Step 1.2: Parser** (storehouse/src/parse_blocks.rs)
- Add `pub fn parse_rule_block(lines: &[&str]) -> (Rule, usize)`.
- In `parse_aggregate`, replace `consume_rule_block(&lines[i..])` call
  (currently just returns consumed lines) with:
  ```rust
  let (rule, consumed) = parse_rule_block(&lines[i..]);
  agg.rules.push(rule);
  i += consumed;
  continue;
  ```
- `parse_rule_block` body recognizes:
  - `when_present :<attr>` → push `RuleGate::WhenPresent`
  - `at_most <n>, where: { ... }` → parse int + reuse `parse_where_line`
  - `at_least <n>, where: { ... }` → same
  - `requires { <expr> }` → extract block via `extract_block`, validate
    single-expression (existing logic from `consume_rule_block`)

**Step 1.3: Dump** (storehouse/src/dump.rs)
- Add `dump_rule` / `dump_rules` following the pattern of `dump_entities`.
- `dump_aggregate` gains `"rules": dump_rules(&agg.rules)`.

**Step 1.4: Runtime** (rust/src/runtime/command_dispatch.rs or equivalent)
- After `apply_mutations`, before `emit_event`: call `check_aggregate_rules`.
- Cardinality check: `repo.query(agg_name, wheres).len() op count` →
  on failure return `RuleFailed { aggregate, rule: name, state_snapshot }`.

**Step 1.5: Ruby parity**
- `lib/hecks/bluebook_model/structure/` — add `Rule` struct.
- `lib/hecks/dsl/` — `rule "name" do ... end` builder: replaces no-op.
- `parity/canonical_ir.rb` — `dump_aggregate` adds `"rules"` key.
- `parity/parity_test.rb` — update goldens; add a Voice.Utterance bluebook
  fixture to the parity corpus.

**Step 1.6: Behaviors**
- `expect_rule_failure "name"` matcher in the behaviors test DSL.

Parity gate: `ruby -Iruby parity/parity_test.rb` must pass before PR open.

---

### Phase 2 — `for_each` block in PM `on`-handler

**Step 2.1: IR** (ir.rs)
- Add `pub for_each_block: Option<ForEachSpec>` to `ProcessManagerHandler`.
  (The per-dispatch kwarg `for_each` on `DispatchSpec` is unchanged.)

**Step 2.2: Parser** (parse_blocks.rs)
- In `parse_pm_handler` / the on-handler body walker, detect `for_each
  "X.y" do` as a block opener.
- Collect all `dispatch "..."` lines inside the block via reuse of
  `parse_dispatch_statement`.
- Parse the `for_each "X.y"` string through `parse_for_each_clause`
  (already exists, used for kwarg form).
- Stamp each collected `DispatchSpec` with the parsed `ForEachSpec` (OR
  put the spec on the handler's `for_each_block` field and let the runtime
  resolve at execution time — the latter is cleaner: one ForEachSpec on the
  handler, runtime iterates and fires each dispatch per record).

**Step 2.3: Dump** (dump.rs + canonical_ir.rb)
- Extend `dump_pm_handler` to include `"for_each_block"` key.

**Step 2.4: Runtime**
- PM execution: when `handler.for_each_block.is_some()`, query the named
  source, iterate, fire each dispatch once per record using `from_iter()`
  resolution (already implemented for the kwarg form in Phase 2.b of the
  original PM arc).

**Step 2.5: Ruby parity**
- ProcessManager handler in Ruby model gains `for_each_block` attribute.
- `canonical_ir.rb` `dump_pm_handler` extended.

---

### Phase 3 — `references_to` (typed reference list)

**Step 3.1: IR** (ir.rs)
- Add `ReferenceList { name, target, domain }` struct.
- Add `pub reference_lists: Vec<ReferenceList>` to `Aggregate` and `Command`.

**Step 3.2: Parser** (parse_blocks.rs)
- In `parse_aggregate` and `parse_command`, add arm for `references_to`:
  extract PascalCase target name and required `as: :name` kwarg (same
  pattern as the existing `reference_to` parser arm in `parse_command`).
- `as:` is mandatory. Parser emits a structured error if absent — no
  default name, no auto-pluralization.

**Step 3.3: Dump + Ruby parity** — follow the same pattern as `reference_to`.

---

### Phase 4 — Behaviors gate per construct

Per i246: each construct needs a `behaviors` test that verifies the runtime
enforces it. These land after the runtime hook in each phase:
- Phase 1: `expect_rule_failure "one mouth"` in a Voice.Utterance behaviors file.
- Phase 2: `expect_for_each_dispatched n_times: 3` (or equivalent) in a
  Fibroblast behaviors test.
- Phase 3: `expect_reference_list "blocked_by"` shape check.

---

## Cards subsumed

| Card | Status | How f4 covers it |
|---|---|---|
| i246 — aggregate-level rules | queued | Phase 1 of this plan is i246's implementation |
| i130 — DDD invariants as rules | queued | `rule` construct in Phase 1 is the structural invariant i130 describes; `invariant` keyword retired to `rule` per i255 |
| i128 — Specifications as first-class | queued | NOT subsumed — `specification` as a reusable named predicate (citable from query where / command given) is a separate concern from `rule`. Defer; see note below |
| i132 — Process managers as first-class | landed | PM first-class is already shipped (i132 landed in 39f279d6). Phase 2 extends the existing PM with `for_each` block form |
| i255 — bluebook rule vocabulary | queued | Phase 1 implements the vocab for `rule`; the broader vocabulary (expects/guarantees/undo_with) is out of scope for f4 |
| i494 — meta-bluebook DSL gaps | queued | Phase 1 closes gap 1 (rule); Phase 2 closes gap 2 (PM `for_each`); gap 3 (query body meta) stays queued; gap 4 (command guards) stays queued; gap 5 (specification etc.) stays queued |

**i128 (specification) is NOT subsumed.** A `specification "Name" do
matches { ... } end` that is CITABLE from query `where` and command `given`
requires the parser to resolve a named reference at IR-link time — a
cross-aggregate-style link within the same bluebook. That's a distinct
phase (Phase 5, not designed here). File a follow-up.

---

## Open questions (flag for Miette)

1. **Cardinality scope.** Does `at_most 1, where: { state: "speaking" }`
   check across ALL records of the aggregate (global invariant) or only
   within the current record's boundary? For Utterance it must be global
   (one speaking across the whole store). The design assumes global; confirm
   for other use cases.

2. **Rule check timing on Capture.** If Utterance is new (Capture command),
   `apply_mutations` has just set state to "queued" — not "speaking" — so
   the rule passes trivially. If Speak command (queued→speaking) is
   dispatched, the mutation fires before the rule check. The rule then sees
   the post-mutation state: correct (we count speaking records AFTER the
   candidate mutation). Confirm this is the intended semantics.

3. **`references_to` placeholder.** story.bluebook can temporarily use
   `attribute :blocked_by, list_of(Ref)` (existing VO-list form) until
   Phase 3 lands. Is that acceptable for the f16-blocked-by-f4 use case, or
   is typed validation at dispatch time a hard requirement for sprint work?

4. **PM first-class vs aggregate for Fibroblast.** fibroblast.bluebook is
   currently an `aggregate + policy`, not a `process_manager`. Should the
   migration to PM form happen as part of Phase 2, or should Phase 2 only
   add the `for_each` block form and leave the Fibroblast aggregate shape
   unchanged?
