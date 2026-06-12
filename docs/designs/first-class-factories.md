# Locked design : first-class factories (Factory is a node, not a flag)

> Decided 2026-06-12 with Chris. Successor to the `creates` bool shipped in
> step 1 (PR #729). Replaces the bool + the `is_create` name heuristic with a
> first-class `Factory` IR node. Companion to `remove-reference-to-keyword.md`.

## Diagnosis

Step 1 (#729) added `Command.creates: bool`, set by a `create` keyword. That
*classifies* a command as a factory but does not *model* the Factory — it is a
command wearing a factory's hat. Three things the bool cannot do :

- It cannot move creation OFF the created thing — Evans's core Factory case : a
  Backlog drafts Stories, a Plan plans Sprints. The bool only ever says "this
  Story-command makes a Story."
- It leaves the `is_create = name.starts_with("Create"|"Add"|…)` heuristic alive
  as the real classifier ; the bool merely ORs into it.
- It keeps `reference_to(Self)` on creators meaningful, so the reference_to
  retirement stays half-done.

## Locked decisions (3 forks)

1. **Scope : self + cross-aggregate.** A `Factory` node may produce its
   enclosing aggregate (default) OR another via `produces:`. The
   cross-aggregate case is the whole point — it is what the bool fundamentally
   cannot express.
2. **Keyword : `factory`.** A distinct block, not the `create` keyword. Reads
   as the DDD concept ; visually separates births from transitions. Costs
   renaming the `create` sites added in step 1 (small — the parity fixture plus
   any nursery uses).
3. **Replace the bool.** Promote `creates: bool` to the Factory node and DELETE
   it + the `is_create` heuristic. No half-measure left behind.

## The shape

### Grammar

```ruby
aggregate "Sprint" do
  identified_by :number
  attribute :number, SprintNumber
  attribute :goal,   Goal

  factory "Plan" do              # births a Sprint
    attribute :number, SprintNumber
    attribute :goal,   Goal
    given { number.positive? }   # invariant enforced AT birth
    emits "SprintPlanned"
  end

  command "Activate" do          # operates on an existing Sprint
    emits "SprintActivated"
  end
end

aggregate "Backlog" do
  # creation lives where it belongs, not on the thing being created
  factory "DraftStory", produces: Story do
    attribute :title, Title
    emits "StoryDrafted"
  end
end
```

### IR

```
Aggregate {
  factories: Vec<Factory>,   // births  — mint new, enforce creation invariants
  commands:  Vec<Command>,   // transitions — load existing, operate
  queries:   Vec<Query>,
  …
}
Factory {
  name:       String,
  produces:   String,        // target aggregate ; default = the enclosing one
  attributes: Vec<Attribute>,
  givens:     Vec<Given>,    // creation invariants, checked at birth
  emits:      Option<String>,
}
```

`Command.creates: bool` is removed — the node TYPE carries the classification.

### Dispatch — two paths, no heuristic

- **Factory** → `Repository.add` : mint a fresh id, ERROR if it already exists,
  apply creation givens, emit.
- **Command** → `Repository.find` : load by universal id, ERROR if absent,
  transition, emit.
- DELETE the `is_create` name-heuristic AND `Command.creates`.
- `produces:` routing — a factory on Backlog producing Story dispatches against
  the Story repository, mints a Story id, emits the Story's created event.

### Grammar bluebooks (domain first)

- `sentence.bluebook` : a Sentence maps to a factory — a third kind of utterance
  beside command / query.
- `bluebook.bluebook` : add a `Factory` entity to the IR contract (sibling to
  Command) ; drop `creates` from the Command entity.

## What it unlocks

First-class factories COLLAPSE the reference_to retirement. A factory births a
thing that did not exist, so `reference_to(Self)` on a creator is meaningless by
construction. Steps 2–4 of `remove-reference-to-keyword.md` (mark creators,
sweep ~589 sites, lock the parser) largely fall out — the node type already
carries the bit ; the sweep becomes "convert creators to `factory`, drop their
`reference_to`."

## Migration (gated, worktree — kernel-floor dispatch rewrite)

Each phase gated on full suite + behaviors + integrity + golden + parity, merge
only green :

1. **IR + parsers + dumps** : add the Factory node (both parsers via their shape
   sources — `ir_shape`, `dump_shape`, `parser_shape`, `parse_blocks_shape`),
   `aggregate.factories`, drop `Command.creates`. Ruby + Rust, parity-gated.
   `factory` keyword builds it ; `produces:` defaults to self.
2. **Dispatch** : route Factory → mint-path, Command → load-path ; delete
   `is_create` + `creates`. `reference_to(Self)` honoring stays (transitional)
   until the sweep. Prove green corpus-wide — this is the silent-regression risk.
3. **`produces:` cross-aggregate routing** : a factory on A producing B mints a
   B. Add a real corpus example (Backlog drafts Story, or Plan plans Sprint).
4. **Migrate step 1's `create` sites → `factory`** ; retire the `create` keyword.
5. **Fold into the reference_to retirement** : convert self-ref creators to
   `factory`, drop `reference_to(Self/Root)` on them, sweep the rest.

## Relationship to PR #729

#729 (the `creates` bool) is SUPERSEDED by this design. Recommended path :
**merge #729 as the documented stepping stone, then this arc deletes the bool.**
#729's infrastructure is reused wholesale — the parser keyword routing, the
dump/parity machinery, the validator `meta` exemption, and the mapped
dispatch-path. The bool deletion is then a clean diff on top. The validator
`meta`-exemption is independently valuable and should land regardless.

## Precision note

Kernel-floor dispatch rewrite + two-parser parity + new cross-aggregate
semantics. Best executed byte-precision fresh in a gated worktree, not at a
session tail. The `is_create` deletion is the silent-regression risk — only the
full corpus run catches a creator that silently flips to a transition.
