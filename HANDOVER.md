# Restart prompt — hecksagain

Paste this into a fresh session.

---

We are building **hecksagain** at `~/Projects/hecksagain` — Hecks rewritten with
Ruby as the source of truth. Read `README.md` first, then this.

## The thesis

Both runtimes are hand-written. Ruby holds the semantics; Rust is a second
implementation held to Ruby's answers. Parity is a claim about OUTPUT, not
origin: the same source file in, the same answers out, **as far as the corpus
reaches**. `bin/parity` is what makes the claim real.

Do not call Rust a projection. Nothing generates it.

## Standing rules

1. **Never modify `~/Projects/hecks`** unless asked. Different repo; reading it is
   a distraction. hecksagain is the whole world.
2. **Don't hand-write what Hecks already has** — cherry-pick whole. But
   simplifying is not copying; that is how `creates?` regressed.
3. **`Pizza.create_pizza(...)` is the public surface; `dispatch` is private
   plumbing.** Served by the class-free facade (`lib/hecksagain/facade/`) —
   per-boot modules closing over the dispatcher. No domain classes are minted
   anywhere; the IR is the only graph.
4. **Zero warnings, zero failing tests.**
5. **Tests do no IO** except `spec/adapters/`.
6. **Ruby wins when the shapes differ.** The exporter converts. Never bend a
   bluebook to suit an interpreter.
7. **Bluebook first, and it is not optional.** Twice in one session a concept was
   built in Ruby and only declared afterwards, both times within an hour of naming
   the reflex out loud. If it is about bluebooks, `bluebook.bluebook` is where it
   goes — declaring the queries took less time than the Struct did.

## Current state

    main                     PR #1 and #2 merged
    experiment/self-hosting  ahead of 6a33483, NOT PUSHED

    bundle exec rspec                             434 examples, 0 failures
    cd rust && cargo test --release --workspace   passing, 0 warnings
    bin/parity     AGREED — banking 102/193 · pizzas 5/18 · grammar 27/37

`core.hooksPath` is LOCAL config — a fresh clone needs
`git config core.hooksPath .githooks` or the pre-push parity gate is silent.

## THE ROUND TRIP IS CLOSED, AND LOSSLESS

`bluebook.bluebook`'s vision — "loading a domain becomes dispatching commands into
this meta-domain ; the IR it stores must equal the IR the DSL builder produces" — is
a test, and there is nothing left to explain:

    Pizzas · Banking · TillRoom · Wire     ZERO differences, all four

`spec/round_trip_spec` compares each against the builder's `to_h`, canonicalising
only the PRESENTATION axis (which position a command occupies in its aggregate's
list, read by nothing). Order that changes behaviour — a command's mutations, a
lifecycle's transitions, a compensation's dispatches — is compared as declared.

The fixtures are in that comparison ON PURPOSE. Banking has no aggregate attribute
carrying a default, so `Field#default` would have been legal and unexercised; till
declares `attribute :balance, Money, default: { cents: 0 }`, which exercises the
field and the object-literal encoding together.

Two things the round trip caught that nothing else could see: an append's field
bindings were stored raw, so `append: { direction: "out" }` — a LITERAL — was
indistinguishable from an argument named `out`; and `Field` had no `default`, so an
aggregate attribute carrying one would have been dropped while the reconstruction
hardcoded nil, matching every corpus member and lying about the first one to declare
a default.

A literal is stored SELF-DESCRIBINGLY, via `inspect` — a number bare, a string
quoted, a symbol wearing its colon, an object wearing its braces. The language
already stores code as text (`canonical: "cents >= 0"`), so an encoding is in
keeping; forgetting the type was the bug. `Readings#encode_literal` writes,
`Shapes#decode_literal` reads.

An ENTITY declares commands and queries, and the IR reuses IR::Command and
IR::Query for them, so the language reuses Command and Query with an `entity_id`
saying which piece declared it. The part that bit: `entity_id` also needs a field on
the Command AGGREGATE, because a command argument with nowhere to land does not
persist — the same lesson `disputed_by` taught on CardPayment.

## How the pieces fit

- `plan.rb` — reads the language's own IR into a plan. Every append command DECLARES
  its target (`then_set :givens, append: {...}`), so the append table AND the whole
  containment tree fall out of the declarations. Appenders are FIRST-WINS with the
  displaced ones kept as `alternates`, because three commands append to `attributes`.
- `judge.rb` — the walk. No branch per category. Declares every sibling before
  detailing any, so a reference can point at a head declared later in the file.
- `readings.rb` — only where the IR's SHAPE differs from the language's: a
  transition whose `from` is a list is several transitions, an open map is one row
  per entry, an append is offered once per binding.
- `reconstruction.rb` + `shapes.rb` — the inverse, reading through the language's
  own `whole_bluebook` read model. 241 code lines against replay.rb's 420, because
  both directions are one table.
- The language spells its fields EXACTLY as the IR spells them. One spelling, so
  there is no translation table to be quietly wrong in.

## Reading a bluebook back

    Meta::Bluebook.Called            the bluebook called "Pizzas"
    Meta::<Root>.DeclaredIn          everything declared in the parent above
    Meta.whole_bluebook              the whole chapter in ONE read (a read model)

Query names are matched EXACTLY and are PascalCase (`.Called`, not `.called`). The
read model's reference argument is the snake of its `reference_to` target
(`bluebook:`), not `reference:`.

Every attribute type is a REFERENCE to whatever it names — a value object, another
aggregate's head, or an entity — so "the type is declared" costs no predicate at
all. Three verbs: `Attribute`, `Reference`, `Holds`. Nothing is skipped.

## What is left

- **The unwind is COARSE and the corpus cannot tell.** `on :refused` is ONE
  compensation for a whole procedure; banking hand-lists two undos in the right
  order, by hand, and the runtime does not know which legs completed. Right for two
  prior steps, wrong for four. Discriminating case: three undoable steps where only
  the first two complete.
- **Five of twelve categories are still pattern names**, not words a bank says:
  `ProcessManager`, `Handler`, `Dispatch`, and the `lifecycle` / `saga` vocabulary.
  The collapse they hide: a procedure is an aggregate advanced by EVENTS instead of
  commands, `correlates_by` is a `reference_to`, and a status is an attribute whose
  values are a closed set with declared moves —
  `attribute :status, TransferStatus do transition … end`. An arc, not a rename.
- **The reconstruction is not yet the SOURCE.** The round trip proves the
  meta-domain holds everything; the runtime still runs the builder's IR. Making
  `Hecks.boot` run the reconstructed one is what "executes" finally means, and the
  comparison above is the safety net for trying it.
- **Two rules genuinely blocked on the sublanguage**: read-model uniqueness needs a
  quantifier, the mutation-target rule needs to reach a list on another root (it
  lives in `AggregateBuilder` and says so). A third looked blocked and was a
  modelling mistake — see the findings.

## Defects written down as expected behaviour — five in one session

The house failure mode. Each PASSED because the thing asserting it agreed with the bug:

- `dsl_spec`'s five `then_set` cases asserted a mutation was recorded while naming
  fields their fixture never declared.
- banking credited an account with `colour: "red"`, succeeded, and wrote the bug
  into its own narrative: *"An attribute the command never declared."*
- `spec/saga_spec` was titled "the compensation puts the money back" and the TEST
  put it back, by hand, one line after asserting the drawer was short.
- banking hand-drove a transfer into a frozen destination through
  `Reject → Debited → Settle` to `"status": "settled"` — money debited, never
  delivered, recorded as done.
- `Aggregate.Seal` carried `given("an aggregate declares at least one attribute")`,
  invented for Seal and never dispatched. First run it refused twenty-five
  bluebooks, and it is not true: a state machine declares no attribute.

AND ONE NEAR-MISS OF MY OWN, worth more than the five because it shows the pattern is
not somebody else's carelessness: closing the last round-trip gap, I added
`Field#default` to the language — and no aggregate attribute in banking carries a
default, so the field was legal and unexercised, about to be committed by the person
who had spent the day narrating that exact failure. `till.bluebook` declares
`attribute :balance, Money, default: { cents: 0 }`, so the round-trip spec now
includes the fixtures and the field is actually exercised.

## Findings worth not rediscovering

- **Both runtimes can be wrong identically, and parity certifies it.** A read
  model's gathered heads derived their name with `snake(target) + "s"` in BOTH
  runtimes, so the meta-domain handed back `querys`, `entitys`, `policys`,
  `dispatchs` — green on every one. There were also TWO pluralisers and only one was
  correct. `Naming.plural` / `naming::plural` are the only copies now.
- **Not all order matters.** BEHAVIOUR-BEARING order must survive: mutations are
  applied in sequence, a lifecycle takes the FIRST matching transition, a
  compensation credits before it reverses. PRESENTATION order need not: nothing
  looks a command up by position, so `ReadModelInterpreter#matching`'s
  `.sort_by(&:id)` is a canonical form and the round-trip comparison sorts both
  sides. "Index for index" is about the two CANONICALISERS being byte-equal — a
  property of the comparison, not of the IR.
- **Ask whether a rule is unsayable or just badly modelled.** The reference-shape
  rule looked like a sublanguage gap (`start_with?` is unavailable and leaks a raw
  `no implicit conversion of Symbol into Integer`). It was a STRING where a
  reference belonged. `reference_to Aggregate, as: :points_at` is stronger than the
  prefix match, because a prefix match only checks the text looks right.
- **`as:` means "a named attribute", not "the root I act on".** Without that a
  command cannot point at another instance of its own kind. Rust's `ir_json.rs`
  needed the same rule (`acts_on_root`) — latent, since the meta-domain is not in
  the parity corpus, and exactly the kind of divergence that later looks like a
  parser bug.
- **`identified_by :name` forbids an argument named `name`.** Bluebook was
  identified by its name AND carried it as a field, so `Bluebook.Normalise` could
  never say what it acts on. It is reached by id now.
- **A refusal is not an event.** `on :refused` is the compensating leg's trigger,
  declared in the `Trigger` vocabulary and bound to `IR::ProcessManager::REFUSED`.
  The DSL needed no change; the Rust PARSER did — `extract_string` takes the first
  quoted string and reached past the symbol to grab the transition's from-state.
- **Procedure and saga are different things.** A procedure coordinates; it is a saga
  when it also undoes. `IR::Saga` is derived from a compensating leg and deliberately
  NOT in `to_h` — a reading of the source, not a fact about it. `saga` appears in no
  `.bluebook` and never should.
- **ENCODING LOSSES ARE THE LARGEST FAMILY OF BUG IN THIS CODEBASE.** Every one has
  the same shape: reading an OBJECT where the IR's `to_h` holds the spelling. The
  count kept growing while I fixed them, so here is the family rather than a number:
  - `order_by` and `limit` stored as `"#<struct LimitSpec value=3>"`, because
    `Array(an_object)` WRAPS rather than destructures.
  - a where-clause's value and every saga dispatch binding lost the colon that tells
    `":ceiling"` the argument from `"ceiling"` the string. `IR.render_value` had
    already drawn that distinction and the walk read past it.
  - an append's field bindings were stored raw, so `append: { direction: "out" }` —
    a literal — was indistinguishable from an argument named `out`.
  - a default and a literal mutation source went through `to_s`, so `0.0` came back
    `"0.0"` and `{ value: "good" }` came back its inspect string.
  - an entity's `identified_by` is a String where an aggregate's is a Symbol, and a
    read-model head's `as` is a String too. The IR is not uniform about this.

  When in doubt, offer what `to_h` spells. **None of these were reachable before the
  round trip existed** — a bluebook that goes in and never comes out cannot tell you
  it went in wrong.
- **Unknown command arguments used to be accepted in silence.** Found by renaming a
  field and watching every stale caller stay green. `UnknownArgument` refuses them in
  both runtimes now; a process manager's correlation key is exempt because a saga
  threads it through every leg — the weakest seam in that gate. The better shape is
  the saga stamping its own key onto the event it caused.
- **A `then_set` naming a field the aggregate lacks wrote nothing and refused
  nothing.** Caught at build now, in `AggregateBuilder#seal_mutation_targets`.
- **AN ARGUMENT WITH NOWHERE TO LAND DOES NOT PERSIST, and this bit twice in one
  day.** First on CardPayment: `disputed_by` was accepted, resolved, gated the
  command — and vanished, because the aggregate had no field for it. Then in the
  meta-domain: `Command.Declare` took `entity_id`, the walk dispatched it correctly
  with both ids, and every entity command still came back unowned, because the
  Command AGGREGATE had no `entity_id` either. A command argument and the field it
  writes into are two declarations, and having one is not having the other.

## Traps that cost real time

- **`bin/parity` cleans up its temp dirs.** The `/tmp/parity.*.json` files are
  STALE — half an hour went into reading yesterday's and reporting three wrong
  conclusions from them. Drive the domain live (`Hecks.boot("examples/banking")` and
  dispatch) or read `bin/parity`'s own output.
- **Hand-probes dirty `examples/banking/data/`.** Run
  `git checkout -- examples/banking/data/` after any script that boots a real domain.
- **`grep saga` matches "heckSAGAin".** Use `\bsagas?\b`.
- **Don't move Ruby blocks with a script that counts keywords.** It finds `do`
  inside a comment and produces unbalanced `end`s somewhere quiet.
- **Make a multi-file edit atomic.** A python script that asserts its anchors as it
  goes can fail halfway, having written one file and not the other — the judge
  started sending `entity_id` while the language had never heard of it, and the
  result was 36 failures that looked like a design error and were a write that never
  happened. Assert every anchor BEFORE writing anything.
- **`cd ~/Projects/hecksagain && …` on every command** — the session cwd is not this
  repo and the shell resets between calls.
- **Don't trust green, and don't trust a filename.** Every real defect this session
  was found by probing by hand or by measuring a diff — never by the suite going red.
