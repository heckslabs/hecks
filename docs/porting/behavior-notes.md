# Hard-won behavior — rules discovered by breaking, not by reading the spec

Every rule below was found by a real bug, a real inconsistency between Ruby and Rust, or a real gap
`bin/parity` exposed — not derived up front. They're consolidated here because each currently lives
only as a comment where its logic happens to sit, which means a new implementation hits every one of
these landmines fresh unless it reads this page first.

Two incidents are worth reading in full before the rest — they're the best argument for why this
page exists at all.

## The two incidents

**A saga silently lost its argument structure and a whole settlement pipeline stopped, with no
error anywhere.** (`lib/hecksagain/bluebook/assembly/marks.rb`, around `def read`.)
`QuerySpecification.render_value` spells a Symbol as `":name"` and everything else via `to_s` — a
where-clause value and a saga's `with:` argument bindings both ride this one spelling. An object
literal rides it too: a saga leg binding `narrative: { text: "transfer out" }` (a value object's
fields written inline) is a Hash, and `to_s` on a Hash is its `inspect` form — so it came back on
read as the literal text `"{:text=>\"transfer out\"}"`. Coercion refused it, the debit leg was never
delivered, and banking's whole transfer settlement wire stopped *silently*: five `TransferRequested`
events, zero `TransferDebited`. Nothing raised — a saga that does nothing looks exactly like a saga
with nothing to do. `bin/parity` caught it because Ruby and Rust disagreed about the resulting
state, not because either runtime complained.

**A refused saga leg used to just get recorded — no compensation ever ran.**
(`rust/src/runtime/dispatcher.rs`, `unwind_saga`.) Before this existed, a refusal was logged and
nothing else happened. Banking's settlement into a frozen destination account left the debit
standing with no credit and no reversal — money taken from the source, gone, with the corpus having
to hand-drive the transfer's state to `"settled"` to even notice. The fix: a refused leg *unwinds* —
runs the leg declared `on :refused`, which is where compensation lives. Re-entrancy is handled for
free: state moves to the compensating leg's own `to_state` *before* its dispatches run, so if the
compensation itself gets refused, the instance is no longer in `from_state` and the second refusal
just gets recorded rather than unwinding again. "The check is the guard" — no separate flag needed.

## Value coercion & value-object flattening

- **A numeric field must arrive as its declared type, checked before invariants.**
  (`lib/hecksagain/runtime/value.rb`'s `check_numeric_fields`; `rust/src/runtime/mutations.rs`'s
  fn of the same name.) Without this, a String in an Integer/Float field only failed later, inside a
  predicate, as `positive? expects a number, got "three"` — a runtime crash (`EvaluationError`), not
  a domain refusal, recorded in the run log beside genuine refusals as if it were one. Checked
  *before* invariants specifically because an invariant reading the mistyped field is exactly what
  used to explode. The error message is byte-identical between the two implementations on purpose —
  parity diffs it.
- **A value object may be appended into an element field the receiving type declares as a scalar.**
  (Rust: `mutations.rs`'s `flatten_scalar_fields`, mirroring Ruby's `Value.scalar`.) E.g.
  `then_set :toppings, append: { amount: :amount }` where the argument is typed `ToppingAmount` but
  `Topping.amount` is a plain `Integer`. Without flattening, Rust stored the whole `{"value":3}`
  object and every predicate reading it failed with `positive? expects a number, got {"value":3}`.
  Only fields the *receiving* type declares as scalar get flattened — a legitimately nested value
  object is left intact; a multi-field value object standing in for a scalar is left untouched
  (Ruby raises `TypeMismatch` there; no corpus case reaches that branch in Rust yet).
- **A command takes only its declared attributes — an unrecognized key used to ride along silently
  and do nothing.** (Ruby: `command_interpreter.rb`'s `refuse_unknown_arguments`; Rust:
  `mutations.rs`'s function of the same name.) The keys that are legitimately *not* attributes:
  `id`, whatever the aggregate is identified by, the reference key of the root a command reaches
  through, and any saga correlation key. This gate is deliberately aggregate-command-only — the
  entity interpreter has no equivalent, on purpose, to avoid splitting the two runtimes over a rule
  neither one enforces symmetrically today.
- **A saga's correlation key legitimately arrives on commands that never declare it.** (Ruby:
  `command_interpreter.rb`'s `correlation_keys`.) Correlation is *routing*, not description — a
  saga threads its key through every leg it dispatches so the emitted event carries it and the next
  step can correlate. Self-noted as the weakest part of the design: the better shape is for the saga
  to stamp its own key on the event it causes rather than smuggle it through the command payload,
  but changing that today would break every saga in the corpus.
- **`MutationOp`'s sign table (increment=+1, decrement=-1, set/append=none) is exported as JSON,
  not hand-copied.** `bin/mutation_ops` regenerates `rust/src/runtime/mutation_ops.json` from
  Ruby's live `CommandRules::MUTATION_OPS`; `spec/vocabulary_conformance_spec.rb` holds all three
  (Ruby table, JSON export, `Vocabulary::MutationOp` in the language) equal. Forgetting to
  regenerate after a change is a silent-drift risk this spec exists specifically to catch.
- **A `one_of` declared but left empty must be distinguishable from no `one_of` at all.**
  (`lib/hecksagain/bluebook/ir/value_object.rb`.) Both used to serialize as `members: []`; recording
  `closed_set?` explicitly lets the runtime tell "closed and admits nothing (yet)" apart from "not
  closed at all" — the difference `admit_member` needs to enforce correctly.

## Reference resolution & aggregate-existence checks

- **`reference_to Customer` is supposed to guarantee the target exists — and for a long time,
  enforced nowhere.** (Ruby: `command_rules.rb`'s `resolve_references`; Rust: `dispatcher.rs`'s
  function of the same name.) Declared 14 times across the `banking` example domain and checked in
  neither runtime — an `Account` could belong to a `Customer` who was never registered, in both
  runtimes equally, and `bin/parity` stayed green because both sides were equally permissive and no
  corpus step ever exercised a dangling reference. Resolved in the *interpreter*, not in coercion —
  coercion is pure and holds no repository. A reference into another domain is deliberately left
  unchecked (may legitimately not be loaded yet, same treatment `across` policies get). Shared by
  both the aggregate and entity interpreters even though no entity command in the real corpus uses a
  reference-typed attribute yet.
- **Every list that can carry a reference-typed attribute has to be stamped with which aggregate
  declared it, at DSL-build time.** (`lib/hecksagain/bluebook/dsl/aggregate_builder.rb`'s
  `stamp_references`.) `resolve_references` skips a `nil` target *silently*, so a reference the
  stamping walk missed fails open instead of loud — stated plainly in-repo as "the exact shape of
  the bug that let an Account belong to an unregistered customer fourteen times over."
- **A reference resolves lazily, through the aggregate's own class constant — never eagerly by
  regex.** (`lib/hecksagain/bluebook/ir/reference.rb`.) Used to be the raw string
  `"Reference<Customer>"`, independently parsed back apart by five different readers (a regex in the
  command interpreter, string equality in the read-model interpreter and the SQLite adapter, a
  `delete_prefix` in the builder) — "five readers of a spelling one writer invented." Lazy
  resolution matters because `reference_to Customer` may name an aggregate declared *later* in the
  same file. `to_s` still spells `"Reference<Customer>"` on purpose — that's the wire contract
  `Attribute#to_h` exports for the Rust parser to read, independent of how Ruby resolves it
  internally.
- **Constant lookup for a reference target must NOT walk up to `Object`.** (`reference.rb`'s
  `resolve`, `false` passed to both `const_defined?`/`const_get`.) Without that, lookup falls back
  to whatever aggregate class an *earlier-loaded chapter in the same process* happened to install as
  a top-level constant, and a reference silently resolves to the wrong domain's class entirely.
- **`reference_to X, as: :name` means "a named attribute," never "the root this command acts on" —
  even when `X` is the command's own aggregate.** (Ruby: `dsl/command_builder.rb`; Rust:
  `projector/ir_json.rs`'s `acts_on_root`.) Without this distinction, a command self-referencing its
  own aggregate kind (the meta-domain's own `Aggregate.Reference` command does exactly this) reads
  as "naming two roots" and gets refused for a reason that isn't real. Both runtimes independently
  hit variants of this bug; Rust's version dropped the reference from attributes *and* claimed it as
  the acted-on root simultaneously.

## Domain refusal vs. runtime crash

- **A central, closed list decides what counts as "the domain judging" versus "the runtime
  breaking."** (`lib/hecksagain/runtime/errors.rb`'s `DOMAIN_REFUSALS`, mirrored in the language as
  `Vocabulary::DomainRefusal`.) A blanket `rescue StandardError` used to fold both into one line
  (`delivered: false, reason: "..."`), so a genuine crash in an interpreter read as ordinary policy
  behavior in the reaction log. `InvariantViolation` was *missing* from this list until a dedicated
  spec caught it on first run — 23 of the `banking` corpus's refusals were exactly this class, and
  without it registered, the policy/saga interpreters (which rescue only this list) let it propagate
  as a crash instead of a decline. `UnknownVerb` is deliberately *included*: a cross-domain policy
  legitimately fires in a deployment where the target domain isn't loaded, and recording the
  undelivered reaction (rather than crashing) is the documented, intended behavior.
- **`UnknownArgument` and `TypeMismatch` are siblings with a precise distinction.** "Right name,
  wrong type" vs. "a name the command never had" — both fire at the payload gate, before any actual
  domain rule runs.

## Expression semantics (see also `grammar.md`)

- **Six comparison operators reduce to two primitives plus a boolean algebra, not a six-way case
  statement**, and that table is declared once (`Vocabulary::Comparison`) and shared: Ruby's live
  `Evaluator::OPERATORS`, checked equal by `spec/vocabulary_conformance_spec.rb`; Rust's copy is a
  compile-time-embedded JSON export (`operators.json`, regenerated by `bin/operators`) — a
  silent-drift risk if the table changes and the export is forgotten.
- **A sign test reuses the exact same comparison primitives against the literal `0`**, rather than
  hand-deriving positive/negative/zero a second time — `apply()` is factored out of `compare()`
  specifically so both call sites share one algebra.
- **The AST is parsed once per distinct canonical string and cached, in both languages** — which
  branch a leaf's grammar takes is a pure function of the string; only the final `state`/`attrs`
  dictionary read varies per call. Ruby's cache is an unsynchronized `||= {}` (redundant work under
  real parallelism, never corruption); Rust's is `OnceLock<Mutex<HashMap<String, Arc<Ast>>>>`, the
  same idiom used elsewhere for process-lifetime globals "even though this binary is
  single-threaded today."

## Literal decode/encode (`marks.rb`) — the largest family of bug in this codebase, in its own words

The module header states this outright: `to_h` spells values as text so a second runtime can read
them, and every spelling has to be inverted somewhere — each method in `Marks` is named after the
spelling it undoes.

- **A closed-set member's fields must be read with `unmark_scalar`, not `unmark`** — a value-object
  `to_h` spells them with `to_s`, and the concrete failure: `member code: "JPY", minor_units: 0`
  came back with `minor_units` as the *string* `"0"`, and a closed set that admits the string would
  refuse the actual number a caller passes.
- **A bare word in an `append`'s field mapping is an argument reference; anything self-describing is
  a literal.** `Mutation#to_h`'s append branch spells each binding as
  `value.is_a?(Symbol) ? value.to_s : value.inspect` — described in-repo as "the whole reason
  `append: { direction: 'out' }` was once indistinguishable from an argument named `out`."
- **A where-clause's literal value must be decoded with `unmark`, not `read`.** Changed after a
  where-clause literal *number* collided with a String field's own text — the same failure mode the
  `read` method's own header comment already documents for symbols and object literals, extended
  here to numbers/booleans so `gt`/`gte`/`lt`/`lte` have something real to compare against.
- **An object is scanned with a regex, never split on `", "`** (`Marks.object`) — a quoted value
  that happens to contain a comma would otherwise tear the parse in half.

## Dispatch order & tracing

- **A `trace`/`dispatch_trace` mechanism exists purely so a spec can observe declared dispatch
  order** (`Vocabulary::AggregateDispatchOrder`/`EntityDispatchOrder` in the language) — `nil`/`None`
  in production, always. Logging happens *after* a step's own work completes, not before,
  specifically so a step that wraps sub-steps (e.g. `normalize_args` internally tracing
  `refuse_unknown_arguments`) logs itself only once everything nested inside it already has — trace
  order is completion order, which is dispatch order.
- **Rust's dispatch-order tests deliberately avoid the real `banking` fixture.** `Runtime::boot` on
  real banking data writes actual Heki/Sqlite files with no in-memory override on the Rust side
  (unlike Ruby's `InMemoryDomain::MEMORY_ADAPTER`) — both languages' dispatch-order tests use a
  small self-contained fixture domain instead.

## Saga / process-manager compensation

*(See the two incidents above — `marks.rb#read` and `unwind_saga` — both live here.)*

- **The compensation trigger (`on :refused`) is not an event name.** No aggregate ever announces it
  — it's the procedure itself noticing that a leg it dispatched was refused. Declared beside
  ordinary event-triggered legs on purpose, since the compensation *is* an ordinary leg; only its
  trigger differs. `Vocabulary::Trigger` declares this as its own closed set (currently one member)
  specifically so the word doesn't live only as a magic string two runtimes happen to agree on by
  coincidence.

## Query comparator semantics

- **A query's arguments are coerced against their declared types exactly like a command's.**
  (Rust: `dispatcher.rs`, mirroring Ruby's `QueryInterpreter#normalize_args`.) Without this, Ruby
  refused `cents: "lots"` against a `Money`-typed argument while Rust silently answered with an
  empty result set — both "worked," but disagreeing about *why* nothing matched. Reads enter through
  the aggregate specifically so they meet the same coercion gate writes do.
- **A where-clause literal is stringified at query-declaration time** (both Rust's parser and Ruby's
  `QuerySpecification.render_value` agree on this independently), making it indistinguishable on the
  wire from a genuine String field's own value (`"5"` the number vs. `"5"` the text) unless the
  comparator's own parsing recovers the type. A kwarg reference never hits this ambiguity — it
  resolves to the caller's real typed value directly.
- **`in`/`contains` read a comma-separated list OR a real JSON array**, trying the array form first
  (each element unwrapped via the same single-field-object convention a scalar reference uses) and
  falling back to CSV text otherwise. This exact convention is independently reimplemented **four
  separate times**: Ruby's `QueryInterpreter`, `Ports::Query::InMemory`, the SQLite adapter, and
  Rust's `dispatcher.rs` — each comment cross-references the others by name. A fifth implementation
  needs this convention spelled out, not rediscovered by reading four existing ones.
- **`gt`/`gte`/`lt`/`lte` are numeric-only and answer `false` silently otherwise** — a where-clause
  never raises the way a `given` predicate does. This permissive contract predates its own
  documentation (`lt` was already this permissive before the others were added to match it).
- **Which comparator implementation actually runs for a given query depends on the adapter.**
  (`lib/hecksagain/ports/query/query.rb`.) `Ports::Query::InMemory.holds?` is what runs for a
  memory- or Heki-backed aggregate query; `QueryInterpreter#holds?` only fires for entity/sub-list
  queries, or when no adapter implements native `:query` support at all — a real "which of three
  parallel Ruby implementations actually executed" gotcha, independent of the Ruby/Rust split.

## Caching/resolution mechanics (parity-relevant, not bugs, but load-bearing invariants)

- **Rust's resolved-aggregate cache is a per-`Runtime`-instance field, not a global static** —
  deliberately, unlike the expression `AST_CACHE`. Two `Runtime` instances can load the same domain
  *name* with different declared content (tests do exactly this), so a global cache keyed only on
  name would leak one instance's answer into another's.
- **Only successful lookups get cached; a failed resolution stays a cheap re-scan.** Simpler than an
  `Option`-typed cache entry, and failures are error paths, not the hot path anyway.

## Cross-runtime output-parity conventions

- **Any list of names embedded in an error message is sorted before formatting**, in both languages
  — e.g. the list of unrecognized argument names in a refusal. Payload key order is whatever the
  caller happened to write, and Ruby/Rust iterate a map differently; an unsorted list would make the
  *same* refusal read differently between the two runtimes, and `bin/parity`'s byte-exact diff would
  catch that as a false SPLIT.
- **Rust reimplements Ruby's `#inspect`-style scalar formatting** (a string gets quotes, a number
  doesn't) specifically because error messages are compared byte-for-byte — this is not incidental
  string formatting, it's part of the contract described in `conformance-kit.md` §3.
