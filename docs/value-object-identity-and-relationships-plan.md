# Value-object identity and relationship vocabulary

**Status:** Proposed implementation plan
**Scope:** Bluebook authoring language, canonical IR, Ruby runtime, Rust parser/codegen, era compatibility, corpus, and generated documentation

## Implementation checkpoint — 2026-08-18

- Checkpoints 0–2 are resolved under focused gates: the superseding ADR, all identity forms, multi-field runtime identity, honest relationship cardinality/traversal, exact Ruby/Rust parser parity for the exemplar, and the additive dependency analyzer are implemented.
- The Wave 3 direct-routing exemplar is resolved for `SafeDepositBox.Visit.Annotate`: receiver identities travel in `to:`, `with:` is strict domain payload, and the correctness-first execution plan is reported with the result.
- Checkpoint 4A is resolved for direct Ruby, handles, reactions, CLI, Forms/JSON, and handwritten Rust host/codegen boundaries. Port operations now use the same `to:`/`with:` boundary; generated Rust port routing remains the focused follow-up.
- Wave 4B query inference is resolved on `Node.GrandparentLabelled` in Ruby and Rust, and policy/process lexical visibility is resolved with `Event.id` remaining routing-only. The port/handler audit found and fixed the shared port-routing seam before any local refusal was added.
- The Memory execution-plan oracle and SQLite pilot are implemented. D1 passes its focused transactional-batch contract; Postgres and PostgresEra implement the same atomic-put contract and load cleanly, with live assertions pending only because no PostgreSQL server is reachable locally.
- The `SafeDepositBox.Rent` behavioral-reference exemplar is resolved: `CustomerNumber` is an ordinary fact and `belongs_to Customer` is retained state. Cross-aggregate value-object resolution prefers an aggregate-local duplicate and otherwise requires one chapter-wide shape.
- The self-host migration recipe is frozen on `language/world/world.bluebook`, and all remaining exact one-symbol identities under `lib/hecksagain/language` have been converted to named value-object identities. Focused Bluebook/World assembly and byte-exact language parser parity pass.
- The one-symbol identity form remains transitional while live self-hosted and domain sources are migrated. Do not apply the final retired/refusal status or corpus-wide regeneration early.
- No full suite has been run. Per the plan, full verification and checked-in regeneration remain Wave 8 activities.

## Intent

Restore identity and relationship vocabulary that reads in domain language:

- a single conceptual identity is declared as a value object, not as one field pointer;
- a multi-field identity value object contributes all of its values, in declaration order;
- an identity value object may be declared separately or directly inside `identified_by do ... end`;
- a compound key may explicitly list two or more attributes already declared on the aggregate/entity;
- `has_many`, `has_one`, and `belongs_to` are live relationship words again;
- each relationship word tells the truth about cardinality instead of being scalar aliases for `reference_to`.
- commands contain no persistence or aggregate-existence vocabulary; the runtime derives an adapter execution plan from each command's semantic read/write dependencies.
- a construct nested beneath another construct can read the facts its parent already owns without redeclaring them as inputs;
- invocation routing identifies the receiving aggregate separately from the command's domain payload.

This deliberately supersedes the identity and relationship portions of ADR 0025. That ADR remains historical evidence; implementation should add a short superseding ADR rather than rewriting the old decision as if it had never existed.

## Current state and drift

The current checkout has:

- 87 live `identified_by :field` declarations;
- no live `identified_by ValueObject` declarations;
- no live `has_many`, `has_one`, or `belongs_to` declarations;
- three relationship keyword rows and four value-object/`as:` identity argument rows marked `deprecated`;
- builders that refuse those seven declarations during normal authoring but accept them during `EraGuard.shadow_parse`.

The runtime already has the useful lower-level representation this change needs. `identified_by` is emitted as an ordered array of paths, and `Runtime::Identity` joins the values reached by those paths through `Naming.identity`. Restoring value-object identity does not require a new identity wire format: a declared identity value object can expand into one path per member.

For example:

```ruby
value_object "BoxIdentity" do
  attribute :branch_code, BranchCode
  attribute :box_number,  BoxNumber
end

identified_by BoxIdentity, as: :identity
```

can continue to emit:

```json
"identified_by": [
  "identity.branch_code",
  "identity.box_number"
]
```

The storage attribute is the value object (`identity`); the record identifier remains the ordered concatenation of its member values.

## Language decision

### 1. The single-field form is removed from live authoring

This form becomes retired in the current grammar:

```ruby
identified_by :number
```

It remains readable only through the frozen-era compatibility grammar. A live declaration receives a refusal that points to a named or inline value object. The same positional shape with two or more symbols remains admitted as the explicit compound-key form described below.

This is a breaking source-language change and requires a Bluebook language-version bump.

### 2. A named identity value object

The restored blockless form is:

```ruby
value_object "AccountNumber" do
  attribute :value, String
  invariant("an account number is present") { value != "" }
end

aggregate "Account" do
  identified_by AccountNumber, as: :number
end
```

Semantics:

- the positional argument must resolve to a value object in the aggregate's value-object namespace;
- `identified_by` mints the attribute, so a separate `attribute :number, AccountNumber` is an error rather than a duplicate declaration;
- `as:` names the minted attribute;
- when `as:` is omitted, the field defaults to the snake-case value-object name (`AccountNumber` becomes `:account_number`);
- the attribute appears at the position where `identified_by` was written, preserving declaration order;
- Aggregate and Entity use the same implementation and rules.

The declaration expands every identity value-object member into an identity path in member declaration order. A one-field value object therefore preserves today's scalar identifier. A multi-field value object produces the same `Naming.identity` join currently used for composite field identities.

### 3. An inline bespoke identity value object

The admitted inline form is:

```ruby
aggregate "SafeDepositBox" do
  identified_by do
    attribute :branch_code, BranchCode
    attribute :box_number,  BoxNumber
  end
end
```

It may name the minted storage field explicitly:

```ruby
identified_by(as: :location) do
  attribute :branch_code, BranchCode
  attribute :box_number,  BoxNumber
end
```

Semantics:

- the block uses `ValueObjectBuilder`; it is not a second identity-specific field DSL;
- the default storage field is `:identity`;
- `as:` overrides that field name;
- the synthesized type is deterministic and visible in IR/docs: `SafeDepositBoxIdentity` for an aggregate and `<Aggregate><Entity>Identity` for a nested entity;
- the synthesized value object is added to the owning aggregate's ordinary `value_objects` collection;
- an explicit value object with the synthesized name is a duplicate-name refusal;
- the block must declare at least one attribute;
- the block cannot be combined with a positional type argument;
- member order is semantic because it is identity concatenation order.

For entities, the synthesized value object still lives in the aggregate namespace because entity value coercion already resolves value objects through the owning aggregate. Do not create a second entity-local value-object lookup rule.

### 4. A compound key from existing attributes

Two or more symbols explicitly declare a compound key:

```ruby
aggregate "SafeDepositBox" do
  attribute :branch_code, BranchCode
  attribute :box_number,  BoxNumber

  identified_by :branch_code, :box_number
end
```

Semantics:

- every symbol must name an attribute the aggregate/entity already declares;
- at least two attributes are required;
- no new value object or storage field is minted;
- each selected attribute contributes its scalar value, recursively flattening a value-object attribute when necessary;
- the list order is identity concatenation order;
- the form cannot take `as:` or a block;
- this is intentionally a compound database/domain key, distinct from saying that one value object is the identity.

This preserves a useful existing capability while removing the ambiguous one-field spelling. A reader can tell immediately whether the author means “this value concept identifies it” or “these several stored facts form its compound key.”

### 5. Multi-field identity concatenation

Identity values are flattened in declaration order:

```text
BoxIdentity(branch_code: "PHX", box_number: 42) -> "PHX:42"
```

Rules:

- use the existing `Naming.identity` join and `IDENTITY_JOIN`; do not introduce a second encoder;
- preserve the existing scalar rendering for String, Integer, Float, Boolean, and references;
- recursively flatten nested value objects in declaration order;
- reject list-valued identity members;
- reject an identity when any required member is absent or blank;
- defaults are applied through ordinary value-object coercion before identity derivation;
- optional identity members are refused at declaration time: an identity cannot be partially known;
- invariants run through ordinary value-object coercion before the concatenated identifier is accepted.

Changing or escaping the `:` separator is outside this work. Existing composite identities already use it; silently replacing it here would re-key records unrelated to this syntax change. Add characterization tests for separator behavior and record a follow-up if collision-safe encoding is desired.

The same result is produced by `identified_by :branch_code, :box_number` when those existing fields hold `"PHX"` and `42`.

### 6. Relationship words return with distinct meanings

The admitted forms are:

```ruby
belongs_to Customer
has_one MailingAddress
has_many Invoices
reference_to SettlementAccount
```

Their default shapes are:

| Declaration | Stored field | Cardinality | Default |
|---|---|---:|---|
| `reference_to Account` | `:account` | one | required unless `optional: true` |
| `belongs_to Customer` | `:customer` | one | required unless `optional: true` |
| `has_one Profile` | `:profile` | one | required unless `optional: true` |
| `has_many Invoices` | `:invoices` | many | empty list |

Additional rules:

- `as:` overrides the stored field name for every relationship word;
- `has_many` accepts the plural domain spelling and resolves the singular aggregate target using the existing naming rule;
- `has_many` is a list of target identities, not a scalar reference under a plural name;
- `optional:` is not accepted by `has_many`; an empty collection already expresses zero related records;
- none of these declarations creates or mutates the inverse side automatically;
- reference existence checks apply to every member of a `has_many` list;
- relationship kind survives in canonical IR so documentation and projections can distinguish `belongs_to`, `has_one`, and neutral `reference_to` even where their stored scalar shapes coincide;
- cycle and aggregate-boundary validation must consume relationship metadata rather than infer meaning from field names.

Implementation should model `has_many` as the already-representable combination of `Attribute(list: true)` and `Reference(target)`, then audit every list reader that currently assumes a list element is a value object. Add relationship kind as an optional additive attribute field (or an equally small dedicated relationship record) rather than encoding it into the type string.

Restoring the former implementation unchanged is explicitly not the goal: its `has_many Invoices` minted one scalar reference named `invoices`. That spelling contradicted its runtime shape.

### 7. Persistence is a runtime byproduct, not domain lifecycle

Do not add `creates`, `saves`, `inserts`, `updates`, `upserts`, or any repository word to the Bluebook command language. A domain command does not know whether an aggregate is new, already persisted, cached, event-sourced, or reconstructed from a snapshot.

Do not infer creation/update from the presence or absence of `reference_to`, either. A business action may carry another aggregate's identity as a fact, while an action against existing state may have no relationship input at all. References describe retained aggregate/entity relationships only; identity value objects cross behavioral boundaries.

Instead, compile every command into a persistence-neutral execution plan:

```text
command declaration
  -> invocation target (routing envelope, outside the command payload)
  -> genuinely new command inputs
  -> read set
  -> write/mutation set
  -> givens, ensures, invariants, and lifecycle-state dependencies
  -> adapter execution plan
```

The runtime chooses the cheapest correct strategy supported by the selected adapter:

| Derived command shape | Preferred adapter strategy |
|---|---|
| Reads no prior state and produces a complete replacement state | atomic put/upsert, with no preliminary lookup |
| Uses an adapter-supported atomic mutation such as increment | atomic conditional mutation, with no aggregate hydration |
| Reads existing fields, `old`, lifecycle state, untouched invariant fields, or non-projectable rules | load/apply/validate/store in one repository transaction |
| Adapter cannot implement the preferred strategy | fall back to load/apply/validate/store |

A state-independent plan is valid only when static analysis proves all required resulting fields and post-command invariants can be evaluated without unknown prior values. “The command does not mention a reference” is never such a proof.

The adapter may report whether its atomic operation inserted, replaced, updated, conflicted, or found no row. Those are runtime outcomes used for concurrency/refusal handling, not facts exposed to the domain command. Optimistic version checks, insert conflicts, retries, and idempotency also remain runtime concerns.

There is no promise that every command avoids a read. If behavior depends on existing state, that state must come from storage, a trustworthy cache/snapshot, or an adapter-native atomic predicate. The promise is narrower and testable: no command pays an unconditional read merely so the runtime can classify it as “create” or “update.”

### 8. Nested constructs see their parent's facts

A command declared beneath an aggregate is evaluated in that aggregate's domain scope. Aggregate fields used by a command are parent state, not command arguments, and must not be repeated in the declaration merely to make them visible:

```ruby
aggregate "Account" do
  identified_by AccountNumber, as: :number
  attribute :balance, Money

  command "Withdraw" do
    attribute :amount, Money

    given("sufficient funds") { balance >= amount }
    then_set :balance, to: balance - amount
  end
end
```

Here `balance` is read from the parent and `amount` is a new fact supplied by the caller. Static analysis derives `balance` as a parent read and write; the author does not spell `balance` in a command signature, add an attribute for it, or pass it back into its own aggregate.

Addressing the receiver is also not a domain argument. The invocation model has two explicit channels:

```ruby
dispatch "Account.Withdraw",
  to: account_number,
  with: { amount: dollars(20) }
```

- `to:` is routing information naming the receiving aggregate identity;
- `with:` is the command payload containing only new domain facts;
- a handle call such as `account.withdraw!(amount: dollars(20))` supplies `to:` through its receiver;
- HTTP paths, message keys, CLI selectors, and policy fan-out map into the same routing envelope rather than smuggling identity into the payload.

The routing envelope may name an identity whether or not storage currently contains it. Existence is an adapter/runtime outcome, not a different command kind. If behavior establishes a fact that no parent can already supply, that genuinely new fact must still come from a command input, a domain derivation, or another declared source; parent visibility must never invent absent state.

Retire bare command self-references such as:

```ruby
command "Freeze" do
  reference_to Account
end
```

They currently serve as an indirect “existing aggregate” flag and mint an aggregate-named addressing keyword. Both jobs move out of the domain declaration: semantic dependencies determine the execution plan, and the routing envelope identifies the receiver.

`reference_to` is legal only where retained domain structure is declared: aggregates and entities. It is illegal inside commands, queries, policies/reactions, events, port operations, and value objects. A behavioral boundary that receives another aggregate's identity declares the identity value object as an ordinary fact instead:

```ruby
command "Transfer" do
  attribute :destination, AccountNumber
  attribute :amount, Money
end
```

This does not claim that the command retains an `Account` relationship or authorize a hidden repository lookup. If behavior must be sent to that account, a policy/process routes a separate command with `destination` as its target. Existing relationships on the parent remain directly visible without redeclaration. Read models/projections that currently use `reference_to` to mean “projection root” must migrate to source/projection vocabulary; they are not retained relationships and must not overload the relationship word.

Apply the same containment principle throughout the language: a nested construct sees facts in its declared lexical/domain scope and declares only facts introduced at its own boundary. Audit aggregate commands, entity commands, givens/ensures, emitted-event mappings, queries, policies/reactions, projections/read models, and port operations for parent identifiers or parent fields redundantly modeled as local arguments. Each construct must define its visibility boundary explicitly; do not make every name globally visible, and do not silently turn a parent-state read into a caller obligation.

This visibility rule is also planning data. A direct reference to a parent field enters the read set; a command-local attribute enters the payload schema; a mutation enters the write set; and a receiver identity enters only the routing schema. These categories must remain distinct in canonical IR, generated APIs, forms, CLI specifications, policies, and both runtimes.

### 9. Known corpus duplication to remove

The corpus already contains several concrete forms of parent-schema repetition. Treat these as migration classes and add a structural checker for each class rather than fixing only the named examples.

#### Entity identity repeated as command input

`SafeDepositBox.Visit.Annotate` redeclares `date` and `sequence`; `SafeDepositBox.KeyIssuance.Return` redeclares `serial`. Those fields identify the receiving entity and belong in the entity routing envelope. Only newly supplied facts such as `note` belong in the command payload.

Entity routing must therefore carry both the containing aggregate identity and nested entity identity without presenting either as command attributes. An entity command can read the entity and aggregate fields visible in its scope.

#### Aggregate schema repeated by state-establishing commands

`Statement.Generate` repeats `account`, `period`, `opening_balance`, `closing_balance`, `generated_on`, and `frequency`. Similar overlap exists in `Account.Open`, `ATMCard.Issue`, `CardPayment.Authorize`, `Transfer.Request`, `ExternalTransfer.Request`, `ScheduledPayment.Schedule`, `Order.CreatePizza`, `Wire.Ask`, and other corpus commands.

Some values are genuinely new command facts, but their field definitions are not new. When a command source maps directly to a parent field, infer its name, type, constraints, optionality, and reference/relationship shape from that parent declaration. The author states the effect; the compiler derives the payload schema. The existing bare `sets :field` implicit-attribute rule proves this model for simple assignments and must be generalized beyond only `:set` and list-append mutations.

Do not confuse “do not redeclare the field” with “do not supply a new value.” A value absent from parent state still needs a declared source: caller input, literal, domain derivation, event/process state, or adapter result. The compiler may infer an input's schema from its destination, but it may never invent the value.

#### Structural relationships repeated by commands

`SafeDepositBox.Rent` repeats `Customer`; `Statement.Generate` repeats `Account`; `Wire.Ask` repeats `source` and `destination`; `Node.Plant` repeats `parent`. Migrate these to effects that populate the already-declared relationship using typed identity inputs. The aggregate/entity owns the relationship declaration; the command owns only the new identity fact and effect.

Any command/query/policy/event/port declaration of `reference_to` receives a targeted grammar refusal explaining the three legal alternatives: use a visible parent relationship, accept the target's identity value object, or route behavior to the target aggregate.

#### Receiver identities embedded in policy/process payload maps

Policies and process managers currently spell target identity as command payload, for example:

```ruby
dispatch Transfer::Debited, with: { transfer: :reference }
trigger Account::FreezeAccount, with: { account: :account }
```

Migrate those to an explicit target channel:

```ruby
dispatch Transfer::Debited, to: reference
trigger Account::FreezeAccount, to: account
```

Only remaining new facts stay under `with:`. Apply the same migration to `wire:`, `number:`, entity identities, and every other current addressing alias. Generated event handlers, saga correlation, policy fan-out, and direct dispatch must all use the same routing-envelope representation.

#### Query parameter types repeated from compared paths

`Node.GrandparentLabelled` compares `parent/parent/label` with a local `label` parameter and then repeats `attribute :label, Label`. Infer the parameter type and constraints from the compared field path when the mapping is direct and unambiguous. An explicit declaration remains necessary when the parameter has a different domain type, performs conversion, or is not tied to one resolvable field.

#### Unnecessary parent-path ceremony

Nested entity rules currently contain paths such as `parent.customer.status` and `parent.account.customer.status`. Name resolution should search the current construct and then its declared lexical parents. Thus an unambiguous parent field is visible as `customer` or `account` without copying it locally or requiring a `parent.` hop. Keep an explicit `parent.` qualifier available when a nearer scope shadows the same name or the author deliberately wants to emphasize the boundary.

#### Shared rules are selected, not recopied

The corpus's named `given` mechanism already centralizes many repeated predicates. Referencing a named parent rule from a command is not field redeclaration: it explicitly selects which rule applies to that behavior. Preserve that selection unless the rule is promoted to a true aggregate invariant that applies universally. Extend lexical rule resolution to nested entities so a rule declared on the aggregate can be selected without retyping an equivalent `parent...` predicate.

## Grammar lifecycle changes

Update the aggregate-local syntax tables as follows:

- `has_many`, `has_one`, and `belongs_to`: `deprecated` -> admitted;
- `identified_by` constant positional argument: `deprecated` -> admitted in Aggregate and Entity;
- `identified_by as:`: `deprecated` -> admitted in Aggregate and Entity;
- `identified_by` symbol/rest argument: admitted with a minimum arity of two; a one-symbol call is a targeted retirement refusal;
- old `identified_by` source/path block: retired and shadow-only;
- new `identified_by` keyword block: admitted, `inner: "ValueObject"`;
- declare `as:` for the inline block form;
- declare relationship arguments (`as:`, `optional:` where applicable) against each restored word.

The grammar already has separate block and blockless rows for `identified_by`, so overloading does not require inventing an optional-body category. The live block row changes from expression source to a nested ValueObject context; the blockless row handles either a value-object constant or two-or-more symbols. If ArgumentSeed cannot currently express minimum variadic arity, add that constraint rather than leaving the “two or more” rule as undocumented parser folklore.

`SyntaxBoot` must be completed so seed rows in all four lifecycle states are dispatched correctly. It currently creates admitted rows and only applies `Deprecate`. This work needs `Retire` handling because the field and historical path-block forms genuinely leave the live projection.

These are target end-state statuses, not all an initial implementation commit. Use a staged lifecycle cutover:

1. add the new admitted forms and make every reader understand the final status model;
2. keep currently-used one-field identity and behavioral `reference_to` forms readable during source migration;
3. admit `has_many` only after reference-list behavior is complete;
4. migrate the self-hosted language and live corpus;
5. flip the old forms to retired and enable their targeted live refusals only when no live source uses them;
6. retain them thereafter only through versioned shadow parsing.

The status flip and corpus migration are one integration checkpoint. Do not leave the main branch in a state where the grammar refuses source that has not yet migrated.

## Canonical IR and assembly

### Identity

Keep the existing `identified_by: [path, ...]` wire field. This avoids a gratuitous runtime and generator rewrite.

The named and inline value-object forms emit a minted identity attribute. The compound-key form emits only paths through existing attributes, preserving their storage shape. Assembly/reconstruction can render paths sharing one value-object head as a named/inline value-object identity and paths with several heads as the compound-key form.

Add structural gates:

- every named-form identity path starts at its one minted identity attribute;
- every inline-form identity path starts at its one synthesized identity attribute;
- every compound-key path starts at an existing aggregate/entity attribute;
- every nested path resolves to a declared member of its selected value object;
- named/inline path order equals value-object member order; compound-key order equals argument order;
- no identity value object contains an optional or list member;
- no aggregate/entity has more than one identity declaration.

### Relationships

Preserve the existing reference target in `Reference<Target>` and the list bit for cardinality. Add only the relationship-kind information needed to reconstruct and document the author's concept.

Assembly must round-trip all four declarations without collapsing them to `reference_to`.

## Ruby implementation slices

### Slice A — shared identity declaration `[SERIAL: language-core owner]`

Work primarily in:

- `bluebook/dsl/identity_declaration.rb`
- `bluebook/dsl/attribute_collector.rb`
- `bluebook/dsl/aggregate_builder.rb`
- `bluebook/dsl/entity_builder.rb`
- `bluebook/dsl/value_object_builder.rb`

Tasks:

1. Split the symbol/rest branch by arity: refuse one symbol and resolve two or more as a compound key.
2. Restore value-object resolution and attribute minting.
3. Generalize `resolve_identity_type!` from exactly one member to all recursively scalar members.
4. Route the inline block through `ValueObjectBuilder` and install the synthesized type.
5. Keep the symbol form only for two-or-more existing attributes and enforce its minimum arity.
6. Share entity and aggregate behavior rather than reintroducing the former duplicate implementations.
7. Preserve the old field/path forms inside an explicit legacy handler used only by shadow parsing.

### Slice B — identity derivation and validation `[PARALLEL after Slice A contract]`

Work primarily in:

- `runtime/identity.rb`
- `runtime/value/coercion.rb`
- entity lookup/collision handling
- model-check and era-shape identity readers

Tasks:

1. Derive all member paths from the coerced identity value object.
2. Flatten nested value objects deterministically.
3. Keep aggregate and nested-entity identity derivation on the same function.
4. Verify duplicate entity detection with multi-field identity value objects.
5. Ensure storage hydration reconstructs the value-object attribute from an identifier only where the encoding is reversible; otherwise require stored state instead of guessing member boundaries.

The last item is important: a colon-joined multi-field identifier cannot in general be split back into a structured value object. `Instance#materialize_identity!` may hydrate a one-field identity from the identifier as it does today, but a multi-field identity must come from persisted structured state or explicit command data. Never guess by splitting the id string.

### Slice C — relationships `[PARALLEL after Slice A contract, exclusive coercion ownership]`

Work primarily in:

- `bluebook/reference.rb`
- `bluebook/attribute.rb` and behavior
- aggregate/entity relationship declarations
- reference validation and repository existence checks
- query/path traversal
- Ruby projectors (Rust projection/generation is owned by the later Rust track)

Tasks:

1. Restore the three builder methods as live declarations.
2. Make `has_many` produce a reference list.
3. Retain relationship kind through IR.
4. Teach coercion, reference checking, forms, query traversal, SQL projection, JSON codecs, and generated Rust types about reference lists.
5. Add explicit refusals for unsupported operations rather than letting reference lists fall into value-object-list assumptions.

### Slice D — command dependency and adapter planning `[DECOMPOSE before delegation]`

Work primarily in command planning/interpreter code, repository ports, and each driven adapter.

Tasks:

1. Separate the invocation target/routing envelope from the domain payload in the dispatcher and all doors.
2. Resolve aggregate/entity parent-field references lexically and derive the command read set from those references, givens, `old`, lifecycle guards, mutation sources, ensures, invariants, and fields left untouched by a partial mutation.
3. Retire command-level bare self-reference and remove `Command#creates?`, `acts_on`, and aggregate-named payload-key behavior as lifecycle/addressing signals.
4. Replace named cross-aggregate command references with ordinary identity-value inputs; reserve relationship metadata for aggregate/entity state.
5. Derive the write set and determine whether the behavior produces a complete valid aggregate state.
6. Represent a persistence-neutral execution plan without adding fields or words to the Bluebook command declaration.
7. Add adapter capabilities for atomic put and supported atomic mutations.
8. Retain load/apply/validate/store as the correctness fallback for every adapter.
9. Keep cross-aggregate identity facts and retained relationships out of lifecycle/strategy classification.
10. Pin concurrency behavior: conditional writes, affected-row zero, conflicts, retries, and idempotency.
11. Audit every nested construct for duplicated parent facts and publish one explicit scope/visibility rule per construct kind.
12. Generalize destination-driven input inference beyond bare `sets :field`, including relationship identity values and directly bound query parameters.
13. Add entity routing envelopes carrying aggregate and entity identity separately from payload.
14. Migrate policy/process `with:` maps so receiver identity is carried by `to:` and only new facts remain in `with:`.

Slice D is not one agent-sized unit. Its routing contract, dependency analyzer, invocation surfaces, adapter capabilities, and corpus cleanup have different prerequisites and must be executed in the waves below. Do not delegate Slice D wholesale.

## Parallel-agent ownership rules

Use isolated worktrees for parallel agents. Every agent starts from the same completed checkpoint, owns an explicit file set, and returns a commit that does not regenerate shared outputs. The integration owner merges the whole wave, resolves any semantic disagreement, regenerates once, and runs the checkpoint gates before releasing the next wave.

### Exemplar-first rule — resolve one slice before fan-out

This rule applies to every implementation section and to the primary agent as much as to delegated agents. A `[PARALLEL]` marker never means “start every occurrence immediately.” It means the remaining occurrences may be delegated only after one representative vertical slice for that section has been merged and resolved.

Every section follows the same five-step loop:

1. **Choose one representative slice.** Prefer a slice that crosses the important boundaries and exposes risk; do not choose the easiest example merely to get a green result.
2. **Implement it end to end under one owner.** Include declaration/IR, Ruby behavior, Rust parity where the section crosses Rust, compatibility, and focused tests as applicable.
3. **Resolve the slice in the integration branch.** Review semantics, naming, refusal wording, wire shape, storage shape, and generated effects. A slice is not resolved while it exists only in an agent worktree.
4. **Codify the result.** Turn what was learned into a shared helper, structural checker, fixture, migration recipe, adapter contract test, or explicit checklist. Record the resolved checkpoint/commit in follow-up agent tasks.
5. **Apply it to the remaining work.** Only now fan out independent occurrences. Remaining agents follow the codified pattern; they do not redesign it locally.

If the exemplar changes a shared contract, stop or discard any speculative fan-out, merge the exemplar, and restart remaining agents from the new checkpoint. Never ask several agents to discover the same abstraction concurrently and reconcile their competing versions afterward.

The exemplar is a real implementation slice, not a disposable spike. It remains in the corpus and its focused test becomes the first regression gate for the section.

### Planned exemplars

| Section | First resolved slice | What must be codified before fan-out |
|---|---|---|
| Identity declarations/runtime | One focused fixture containing named single-field, named multi-field, inline, compound-key, and nested-entity identity | Shared declaration helper, path expansion/flattening rule, hydration boundary, Ruby/Rust fixture parity |
| Relationships | One two-aggregate fixture exercising `belongs_to`, `has_one`, and a real `has_many` list through Memory | Relationship-kind IR, list coercion/existence checking, naming/cardinality rules, assembly round trip |
| Dependency planning/persistence | One small domain containing a complete state-independent command and a state-dependent mutation | Read/write-set representation, plan-selection rule, transactional fallback, equivalence assertions |
| Receiver/entity routing | `SafeDepositBox.Visit.Annotate`, removing repeated entity identity from payload | Aggregate+entity routing envelope, direct-dispatch/handle contract, refusal and payload-shape assertions |
| Parent visibility/input inference | `Account.Debit` for parent state plus caller input | Lexical lookup order, read/write-set contribution, shadowing/`parent.` rule, inferred payload schema |
| Query inference | `Node.GrandparentLabelled` | Compared-path type inference and the conditions that still require an explicit parameter declaration |
| Behavioral cross-aggregate identity | One existing command-level `reference_to` migrated to a typed identity fact and explicit target | Target-versus-fact checklist and targeted refusal wording |
| Invocation surfaces | Direct Ruby dispatch/handle for the routing exemplar | One routing-envelope adapter API consumed unchanged by policy/process, forms/CLI/HTTP, and Rust surfaces |
| Driven adapters | Memory as semantic oracle, then SQLite as the first non-memory capability implementation | Common capability/outcome contract and adapter agreement examples before Postgres/D1/Rust fan-out |
| Self-hosted language | One small concept file, beginning with `language/world/world.bluebook` | Language migration recipe, parser/assembly expectations, and generated-diff checklist |
| Banking migration | `safe_deposit_boxes.bluebook` | Identity/entity-routing/relationship migration checklist before other Banking concept files |
| Other corpus migration | One Pizzas aggregate plus one focused parser fixture | Domain-source recipe and fixture recipe before dividing remaining examples/fixtures |
| Documentation | The identity section of the aggregate/value-object guide | Final terminology, examples, and cross-link pattern before updating the remaining prose |
| Generated artifacts | One temporary regeneration/diff reviewed by the integration owner | Exact regeneration command/order and expected-diff inventory before rewriting all checked-in projections |

An exemplar may satisfy more than one row when it genuinely crosses those boundaries, but each section still needs its own codified result before that section fans out.

### Surgical verification during an exemplar

Do not run the full test suite while discovering or resolving a vertical slice. Fast, local evidence is part of the method: it keeps the feedback tied to the contract being designed and prevents unrelated failures or expensive regeneration from obscuring the slice.

During an exemplar:

- run the smallest focused spec file/example that exercises the changed declaration, runtime path, adapter, or surface;
- add a dedicated focused spec when an existing broad suite is the only way to reach the behavior;
- run one fixture through Ruby/Rust parser parity only when the slice crosses the parser boundary;
- run the affected Rust crate/test target, not every Rust crate;
- run one adapter contract example against the adapter being piloted, not the whole adapter matrix;
- use temporary output for parser tables, goldens, reference pages, and generated Rust; inspect the diff without rewriting every checked-in artifact;
- run `git diff --check` and inspect the slice's file/stat diff before integration;
- record the exact focused commands and results in the slice handoff so fan-out agents can repeat them.

The exemplar resolution checkpoint runs the focused slice gates plus the narrow contract gates it could invalidate (for example syntax conformance and assembly for a grammar slice). It still does not run the full repository matrix.

After the exemplar is resolved, fan-out agents use the same surgical gate for each remaining occurrence. A broader wave checkpoint runs the affected subsystem suites after all occurrences in that wave are integrated. Corpus-wide regeneration and the complete Ruby/Rust verification matrix remain Wave 8 activities, except for the one self-host/parser regeneration explicitly required at Checkpoint 6.

Escalate verification only when the slice changes a boundary wider than expected. Do not substitute a full suite for identifying that boundary precisely.

### Single-owner files and activities

The following are merge hotspots or generated contracts and must have one owner within a wave:

- distributed `KeywordSeed`/`ArgumentSeed` rows for Aggregate and Entity, plus `SyntaxBoot`;
- `dsl/identity_declaration.rb`, `dsl/attribute_collector.rb`, `dsl/aggregate_builder.rb`, and `dsl/entity_builder.rb`;
- canonical IR/assembly contract changes, including relationship kind, routing-envelope shape, and execution-plan shape;
- shared coercion (`runtime/value/coercion.rb`), unless the wave explicitly assigns it to one track and every other track consumes its frozen interface;
- repository/adapter capability interfaces;
- `rust/parser/src/keywords.rs`, generated model/codegen output, golden IR, generated reference pages, and README indexes;
- final corpus-wide rewrites and the final full-suite verification run.

Parallel agents may add focused fixtures/specs in separate new files, but one integration owner reconciles shared allowlists, registries, snapshots, and generated artifacts.

### Safe parallel boundaries

- Ruby runtime identity work and Rust parser identity work may proceed in parallel after the Ruby declaration/IR contract is frozen.
- Relationship list behavior may proceed beside identity runtime work only when it exclusively owns shared coercion and exposes a settled helper/API to the identity track; otherwise run it immediately after identity runtime integration.
- Routing surfaces (direct dispatcher/handles, policy/process routing, user-facing doors, Rust generation/runtime) are separate tracks after the routing-envelope contract and core dispatcher behavior are frozen.
- Driven adapters are independent after repository capabilities, conflict outcomes, and fallback semantics are frozen.
- Corpus migrations are independent by domain after Ruby/Rust semantics and all invocation surfaces are green. They must not edit frozen era source or generated output.
- Documentation prose can proceed beside corpus migration after syntax and runtime behavior are final. Generated references wait for integration.
- Verification families can run concurrently in isolated worktrees after regeneration; the integration owner still runs one final serialized verification pass in the merged tree.

## Rust parser and generator parity

The Rust side must land in the same change series, not as follow-up drift.

Parser work:

- parse blockless `identified_by ValueObject, as:`;
- reject field-form identity in live input;
- parse `identified_by do`/brace bodies as inline ValueObject declarations;
- synthesize exactly the same names and paths as Ruby;
- parse a two-or-more-symbol argument list as a compound key while refusing one symbol;
- expand multi-field value-object members in declaration order;
- parse all restored relationship words and preserve relationship kind/cardinality;
- refuse `reference_to` outside aggregate/entity structural state declarations;
- resolve unambiguous names through lexical parent scopes while retaining explicit `parent.` disambiguation.

Generator/runtime work:

- generate a structured identity value-object field;
- derive the same concatenated identifier as Ruby;
- encode/decode reference lists;
- validate every referenced id in a `has_many` value;
- generate the same command read/write dependency plan as Ruby;
- keep receiver identity in the generated routing envelope rather than generating it as a command field;
- resolve visible parent fields without duplicating them in generated command payload types;
- generate typed identity inputs, not reference-typed behavior inputs, for cross-aggregate facts;
- generate separate aggregate/entity routing envelopes and policy/process `to:` mappings;
- select an equivalent atomic or transactional adapter path without changing domain semantics;
- preserve byte-exact IR parity.

Regenerate `rust/parser/src/keywords.rs` from the distributed syntax tables; do not hand-edit it.

## Corpus migration

Migrate the language's own bluebooks first, because they exercise assembly and self-hosting before examples do.

For a single-field identity:

```ruby
# before
identified_by :number
attribute :number, AccountNumber

# after
identified_by AccountNumber, as: :number
```

This should preserve the attribute name, value shape, identity string, and storage schema.

An existing composite identity is already the admitted compound-key form:

```ruby
identified_by :branch_code, :box_number
attribute :branch_code, BranchCode
attribute :box_number,  BoxNumber
```

It requires no source or storage migration. Only one-symbol declarations migrate to a value-object form. A domain may separately choose to replace a compound key with a named/inline multi-field value object, but that is a storage-shape change requiring explicit era review rather than a mechanical part of this language migration.

Migration order:

1. Bluebook/World/Hecksagon/Translation language chapters.
2. Paging and other attached sub-languages.
3. Small fixtures and parser parity corpus.
4. Pizzas and other examples.
5. Banking, with explicit treatment of every composite aggregate/entity identity.
6. Frozen era fixtures only through translation/legacy compatibility; never rewrite attested historical source merely for style.

Add at least one real, non-test-only use of each restored relationship word. A word should not return to the live grammar with only a synthetic conformance example.

As part of the same corpus pass, remove every bare command self-reference after its runtime consumers have moved to explicit routing. Audit generated call sites for `account:`, `order:`, and equivalent aggregate-named addressing aliases; migrate them to a receiver, route selector, or `to:` envelope. Replace named cross-aggregate behavior references with typed identity inputs; retain `reference_to` only on aggregate/entity state. Then audit other nested constructs for local arguments that merely repeat a visible parent field, removing each only after its scope and generated boundary remain unambiguous.

## Compatibility strategy

`EraGuard` already tries normal parsing and falls back to shadow parsing. Preserve that boundary:

- old `identified_by :field`: shadow-only after migration;
- `identified_by :a, :b` (two or more): normal live compound-key syntax;
- old `identified_by ValueObject, as:`: normal live syntax again;
- old path-source `identified_by do field.value end`: shadow-only;
- new nested declaration `identified_by do attribute ... end`: normal live syntax;
- historical scalar `has_many`/`has_one`/`belongs_to`: shadow parser reconstructs their historical scalar shapes;
- current restored relationship words: normal parser builds their new declared cardinality.

The same spelling of `has_many` therefore has different historical and current semantics. Language/era version must select the interpretation; a bare `shadow_parsing?` flag is acceptable for held source, but canonical IR and storage-shape comparisons must retain which version produced the shape.

## Documentation and decision records

1. Add an ADR superseding ADR 0025's Identity and References sections.
2. Update the aggregate/value-object guide around identity-as-a-value-concept.
3. Generate reference pages showing all three admitted identity forms.
4. Document relationship cardinality with examples that show actual stored/query behavior.
5. Remove claims that the restored words are “gone.”
6. Explain that a composite identity's field order is semantic and requires migration when reordered.

## Verification gates

### Declaration and grammar

- syntax lifecycle correctly projects admitted and retired rows;
- Ruby builders and declared grammar agree in both directions;
- the generated parser enforces the retired one-field form and excludes the retired path-source block form;
- all admitted forms have generated reference documentation and running examples.

### Identity behavior

- named one-field VO preserves its scalar identifier;
- named multi-field VO joins every member in declaration order;
- inline identity synthesizes deterministic type/field names;
- compound-key identity reads two or more existing fields without changing their storage shape;
- `as:` overrides only the field name, not the value-object member order;
- nested VO identity flattening matches Ruby/Rust;
- missing, blank, optional, or list members refuse clearly;
- duplicate aggregate/entity identities are detected;
- reordered identity members are visible as era/storage-shape drift;
- multi-field hydration never guesses by splitting an identifier string.

### Relationships

- `has_many` stores and returns a list;
- every list member is existence-checked;
- `has_one`/`belongs_to` honor required/optional cardinality;
- `as:` survives IR, assembly, docs, query traversal, and generated code;
- no inverse relationship is silently created;
- relationship cycles receive the existing graph validation appropriate to their direction.

### Command execution and persistence

- no persistence or aggregate-existence word is added to the command grammar;
- `reference_to` never determines insert/update behavior;
- receiver identity is carried outside the command payload on every invocation surface;
- a handle supplies its receiver identity without requiring the caller to pass it again;
- parent fields referenced by command rules/effects are resolved from parent scope and enter the read set without becoming command arguments;
- bare command self-references and their aggregate-named payload aliases are absent from the live corpus;
- `reference_to` is refused outside aggregate/entity structural relationship declarations;
- cross-aggregate behavior inputs use the target's identity value object without implying a retained relationship or hidden lookup;
- forms, CLI, HTTP, policies, and direct dispatch agree on the target-versus-payload separation;
- entity calls route aggregate and entity identity outside payload;
- policy/process `to:` selects the receiver and `with:` contains only new facts;
- directly mapped command/query inputs inherit parent field type and constraints without repeated declarations;
- lexical parent lookup removes unambiguous `parent.` ceremony but preserves explicit disambiguation;
- read-set derivation catches every old-state dependency;
- a state-independent complete command performs no preliminary repository lookup;
- incomplete or state-dependent commands use the transactional load path;
- atomic increment/other supported mutations preserve the same givens, ensures, invariants, and concurrency behavior as the hydrated path;
- an adapter lacking an optimization falls back without semantic drift;
- Ruby and Rust choose semantically equivalent plans;
- insert/update/conflict outcomes remain runtime results rather than command declarations.

### End-to-end

- Bluebook assembly round-trips the language itself;
- all frozen IR fixtures are intentionally regenerated or explicitly unchanged;
- Ruby/Rust parser parity remains byte-exact across the complete corpus;
- Ruby/Rust codegen parity remains byte-exact;
- generated Banking and Pizzas crates compile and pass round-trip tests;
- era guard tests cover old one-field form, old path block, old scalar `has_many`, and every restored live form;
- `git diff --check` and generated-reference drift gates pass.

## Sequenced execution and parallel waves

`[SERIAL]` means one integration owner because the work freezes a shared contract or touches merge-hot files. `[PARALLEL]` means independent agents may run concurrently from the preceding checkpoint, subject to the ownership rules above. No downstream wave starts from a partially merged prior wave.

### Wave 0 — decisions and characterization `[SERIAL]`

1. Land the superseding ADR.
2. Characterize current identity joining, hydration, relationship/reference shape, legacy shadow parsing, command addressing, adapter conflict behavior, and read-before-write behavior.
3. Freeze the additive canonical contracts needed by later work:
   - identity declaration/path rules and minimum compound-key arity;
   - relationship kind and reference-list representation;
   - routing envelope versus command payload;
   - read/write dependency-plan representation;
   - repository capability and outcome vocabulary.
4. Inventory all shared/generated files and assign one integration owner.

**Checkpoint 0:** the ADR, examples, IR shapes, and failing characterization/contract specs agree. Later agents do not invent alternate shapes locally.

### Wave 1 — language and IR kernel `[SERIAL: language-core owner]`

First resolve one focused declaration/IR fixture that contains all three identity forms and all three relationship kinds. Implement only enough grammar, shared DSL, canonical IR, assembly, and shadow compatibility to round-trip that fixture. Use its focused syntax/assembly examples rather than the full suite. Review and freeze its naming, paths, minimum compound-key arity, relationship-kind representation, and compatibility boundary before applying the mechanism elsewhere.

After that exemplar is resolved:

1. Add the remaining grammar rows and lifecycle machinery; make `SyntaxBoot` honor retired seed rows, but defer refusal/status flips for forms still used by the live corpus.
2. Apply the resolved declaration mechanism to all Ruby identity declaration paths in the shared DSL module.
3. Apply the relationship representation to all aggregate/entity builders, but keep `has_many` hidden until real list behavior exists.
4. Update the remaining assembly/reconstruction paths and structural gates for the frozen identity/relationship IR.
5. Preserve every remaining field/path and historical scalar-relationship behavior behind the legacy/shadow boundary.

An optional test-only agent may prepare new isolated legacy fixtures during this wave, but it must not edit DSL builders, syntax tables, shared spec allowlists, or generated output.

**Checkpoint 1:** Ruby can build and round-trip the new declarations; currently-used old forms remain readable during migration; legacy fixtures still parse through the intended boundary; syntax/assembly gates pass. This commit is the base for every Wave 2 agent.

### Wave 2 — identity, relationship, parser, and planner foundations `[PARALLEL]`

Run up to four exemplar tracks from Checkpoint 1. Each track stops after its first slice; it does not sweep the remaining runtime, parser, or planner code yet:

| Track | First slice | Exclusive scope after resolution | Delivers |
|---|---|---|---|
| **2A — Ruby identity runtime** | The focused all-forms identity fixture | `runtime/identity.rb`, identity hydration, entity lookup/collision, era identity readers and focused specs | Multi-field/nested flattening, no guessed reverse split, duplicate detection, legacy identity behavior |
| **2B — Ruby relationship runtime** | The two-aggregate Memory relationship fixture | `Reference`/relationship behavior, reference-list validation, query/path traversal, and **exclusive ownership of shared value coercion for this wave** | Honest `has_one`/`belongs_to`; real `has_many` lists; existence checks and focused adapter-neutral specs |
| **2C — Rust parser** | Ruby/Rust byte-shape parity for the focused identity/relationship fixture | `rust/parser/**` except checked-in generated keywords | All three identity forms, compound-key arity, restored relationships, structural `reference_to` refusal; byte-shape fixtures |
| **2D — additive planning core** | The small state-independent/state-dependent command domain | New dependency-plan/lexical-resolution modules and new focused specs only; no dispatcher or adapter rewrites yet | Read/write-set analysis, parent-scope lookup, complete-state classification, correctness-first plan selection |

If 2A needs to change shared value coercion, 2A and 2B are not parallel: finish and merge 2A first, freeze the helper interface, then run 2B. Do not resolve that overlap by letting both agents edit the file.

**Checkpoint 2P — exemplars resolved:** merge the four first slices, reconcile the shared fixture shapes, and codify the identity helper, relationship coercion API, Ruby/Rust parity fixture, and dependency-plan assertions. Run only those focused examples and the narrow syntax/assembly contract gates they cross. Give every track the resolved commit and exact surgical commands; only then resume the tracks across their remaining exclusive scope.

The integration owner regenerates `rust/parser/src/keywords.rs` once after merging the tracks.

**Checkpoint 2:** Ruby identity and relationships behave end to end; `has_many` can now be admitted; Rust parser parity passes for declaration IR; the dependency analyzer is additive and tested but not yet selecting production execution paths.

### Wave 3 — core routing and execution integration `[SERIAL: runtime-core owner]`

First carry `SafeDepositBox.Visit.Annotate` end to end through direct Ruby dispatch/handle: move aggregate and entity identity into the routing envelope, leave only facts in the payload, select the correctness-first persistence path, and prove the focused refusal/payload assertions. Resolve and freeze that routing contract before changing other command paths.

Then:

1. Apply receiver/payload separation to the remaining central invocation/dispatch paths.
2. Integrate the dependency analyzer and lexical parent resolver into the remaining command interpretation paths.
3. Make load/apply/validate/store the correctness baseline selected by every plan.
4. Remove `Command#creates?`, `acts_on`, bare self-reference, and aggregate-named payload-key behavior from core lifecycle/addressing decisions.
5. Apply the resolved entity routing-envelope shape (aggregate identity plus entity identity) everywhere.
6. Freeze policy/process `to:` semantics and the repository capability interface.
7. Add targeted core refusals for behavioral `reference_to`.

**Checkpoint 3:** direct Ruby dispatch and handles prove target/payload separation, parent reads, entity routing, and transactional fallback. Invocation and repository interfaces are now stable enough for surface and adapter agents.

### Wave 4A — invocation surfaces `[PARALLEL]`

The direct Ruby `SafeDepositBox.Visit.Annotate` result at Checkpoint 3 is the resolved invocation-surface exemplar and supplies the one routing-envelope API all surface tracks must consume. Run these tracks from that checkpoint with non-overlapping surface ownership; each track first ports one call of the exemplar, resolves its focused boundary test, and only then applies the same adapter to its remaining calls:

| Track | Scope |
|---|---|
| **4A-1 — Ruby programmatic surfaces** | facade/handles, direct dispatch callers, ports and ordinary Ruby APIs |
| **4A-2 — reactions** | policies, process managers, event handlers, fan-out, `to:`/`with:` mappings and saga correlation |
| **4A-3 — human/external doors** | forms, CLI, HTTP/web, MCP/query doors and their request schemas |
| **4A-4 — Rust surfaces** | Rust codegen/runtime/host routing envelopes and generated API shapes |

Each track updates only its focused tests. Shared command IR, dispatcher contracts, and generated domain output remain owned by the integration owner.

**Checkpoint 4A:** every invocation surface agrees on receiver versus payload, including nested-entity receiver identity and policy/process targeting; Ruby/Rust boundary fixtures agree.

### Wave 4B — lexical visibility and schema inference `[PARALLEL]`

Before the family audit, resolve the existing Banking `Account.Debit` command serially as the parent-visibility exemplar: prove lexical parent-state lookup, caller-input inference, read/write-set contribution, shadowing, explicit `parent.` disambiguation, and canonical payload schema with focused command examples. Codify those rules in the shared resolver/checker.

Only after that exemplar is merged may agents audit construct families independently:

| Track | Scope |
|---|---|
| **4B-1 — commands and entities** | parent state reads, entity routing inputs, givens/ensures/invariants, mutation-source and destination schema inference |
| **4B-2 — queries and projections** | compared-path parameter inference, projection-source vocabulary, read-model/query parent visibility |
| **4B-3 — policies and processes** | visible parent facts, target identity facts, event mappings, shared-rule lookup |
| **4B-4 — ports and remaining nested constructs** | port operations, events/handlers and the residual containment audit |

These agents add structural checkers for their migration class, not one-off corpus fixes. A single integration owner reconciles name-shadowing and explicit `parent.` behavior across all families.

**Checkpoint 4B:** every construct kind has one explicit visibility rule; inferred inputs remain visible in canonical payload schemas; behavioral `reference_to` is refused everywhere outside aggregate/entity state.

### Wave 5A — adapter contract and reference implementation `[SERIAL]`

First run the small planning domain from Wave 2D through Memory, covering one complete state-independent command and one state-dependent mutation. Resolve capability calls, outcomes, and equivalence to load/apply/validate/store using only those focused contract examples, then extract the shared adapter agreement recipe.

After that Memory exemplar is resolved:

1. Finalize the remaining atomic put/mutation capability calls, transaction fallback, conflict/no-row outcomes, retries, and idempotency expectations.
2. Apply the agreement recipe throughout the Memory adapter as the executable semantic reference.
3. Prove every remaining optimized plan is behaviorally equivalent to load/apply/validate/store for givens, ensures, invariants, lifecycle guards, and conflicts.

**Checkpoint 5A:** adapter contract specs and the Memory oracle pass; other adapters have a fixed target rather than independently designing semantics.

### Wave 5B-P — first driven adapter `[SERIAL: SQLite exemplar]`

Implement the resolved Memory planning slice in SQLite, including its atomic path, transactional fallback, conflict/no-row outcomes, and focused adapter agreement examples. Resolve SQL shape and any necessary refinement to the common capability contract before another adapter begins. D1 does not share-edit or speculate on the SQL abstraction during this pilot.

**Checkpoint 5B-P:** Memory and SQLite agree on the exemplar's observable results. The common capability/outcome contract, SQL recipe, and focused agreement commands are frozen for the remaining adapter agents.

### Wave 5B-F — remaining driven adapters `[PARALLEL]`

Run adapter tracks from Checkpoint 5B-P. Each track first ports the same planning slice, merges and resolves its focused agreement example, and then applies the recipe to its remaining operations:

| Track | Scope |
|---|---|
| **5B-1 — D1** | resolved SQL shape plus D1-specific atomic/transaction behavior |
| **5B-2 — Postgres** | plain Postgres implementation and concurrency specs |
| **5B-3 — PostgresEra** | lineage/era-aware implementation, translations and backfill interaction |
| **5B-4 — Rust host/adapters** | equivalent plan selection, outcomes and fallback behavior |

Repository interfaces and shared adapter agreement specs are integration-owner files. Adapter agents add implementation-specific specs and do not weaken the common contract.

**Checkpoint 5B:** affected adapter agreement suites, conflict behavior, transactional fallback, and Ruby/Rust plan equivalence pass across every real adapter. The complete repository matrix still waits for Wave 8.

### Wave 6 — self-hosted language migration `[SERIAL: language-core owner]`

First migrate only `language/world/world.bluebook`. Resolve it through focused self-use, assembly, syntax-conformance, and Ruby/Rust parser-parity checks using temporary generated output. Review its source and generated diff, then codify the self-host migration recipe.

After that exemplar is resolved:

1. Apply the recipe to the remaining Bluebook, World, Hecksagon, Translation, and attached sub-languages.
2. Remove behavioral references and repeated parent facts only after the relevant structural checker is active.
3. Regenerate parser/model artifacts once and run the affected self-host/assembly/parity gates.

The self-hosted language goes first because every other migration and generated parser table depends on it.

**Checkpoint 6:** the language describes itself using the new identity, relationship, routing, and visibility rules with no compatibility shortcut.

### Wave 7P — corpus and prose exemplars `[PARALLEL]`

Run one source-only exemplar per track from Checkpoint 6, then stop:

| Track | Exemplar |
|---|---|
| **7A — Banking** | `safe_deposit_boxes.bluebook` and its focused source/runtime specs |
| **7B — Pizzas and other examples** | one Pizzas aggregate and its focused source spec |
| **7C — fixtures/corpus** | one focused parser fixture representing the live migration recipe |
| **7D — prose docs** | the identity section of the aggregate/value-object guide |

**Checkpoint 7P — migration recipes resolved:** merge and review all four exemplars; reconcile terminology, source style, identity/entity-routing treatment, fixture conventions, and cross-links. Codify separate domain-source, fixture, and prose checklists. Run the exemplar's focused checks only, then give remaining agents the resolved commit and recipes.

### Wave 7F — remaining corpus and prose migration `[PARALLEL]`

Apply the resolved recipes from Checkpoint 7P:

| Track | Remaining scope |
|---|---|
| **7A — Banking** | remaining concept-folder bluebooks and Banking-specific source specs; explicit review of every compound/entity identity |
| **7B — Pizzas and other examples** | remaining non-Banking example bluebooks and their source specs |
| **7C — fixtures/corpus** | remaining parser, era, model-check and behavior fixtures, excluding attested frozen-era rewrites |
| **7D — prose docs** | remaining ADR follow-up, guides and handwritten examples; no generated reference pages or README indexes |

Within each domain, remove bare self-references, addressing aliases, repeated schema, and unnecessary `parent.` paths only when the compiled payload/routing shape remains explicit. Add real uses of `has_many`, `has_one`, and `belongs_to` across the corpus.

Frozen era source belongs to the compatibility owner. If a current storage shape changes, translations/backfills may be prepared in parallel by domain, but attestation/rekey decisions and final era fixtures are merged serially.

**Checkpoint 7:** every live source corpus member loads and exercises the restored vocabulary; frozen history remains readable; domain-focused suites pass without generated-file changes.

### Wave 8 — integration, regeneration, and verification

1. `[SERIAL]` Merge all migrations; resolve semantic conflicts; review era translations/backfills and rekeys; verify the live-source inventory is clean; then apply the final lifecycle status/refusal cutover.
2. `[SERIAL exemplar]` Regenerate one representative projection into temporary output, inspect its exact diff and ordering, and freeze the regeneration command plus expected-diff inventory. Do not run the complete regeneration until this exemplar is resolved.
3. `[SERIAL]` Apply that recipe to regenerate parser keywords, model/codegen output, IR goldens, reference pages, README indexes, manifests, Banking/Pizzas Rust output, and other checked-in projections exactly once.
4. `[PARALLEL, isolated worktrees]` Run independent verification families:
   - Ruby syntax/assembly/runtime/corpus specs;
   - Rust crate unit/integration tests;
   - Ruby/Rust parser and codegen parity;
   - docs/reference/golden/era/adapter agreement gates.
5. `[SERIAL]` Run the complete merged verification matrix once more, followed by `git diff --check` and a generated-drift audit. This is the first full-suite run required by the plan.

`has_many` is admitted only after list semantics pass end-to-end. Do not temporarily expose the former scalar behavior merely to make the keyword live sooner.

## Completion criteria

This plan is complete when an SME can read all of the following literally and the runtime shape agrees:

```ruby
aggregate "Customer" do
  identified_by CustomerNumber, as: :number
  has_one MailingAddress
  has_many Accounts
end

aggregate "SafeDepositBox" do
  belongs_to Customer

  attribute :branch_code, BranchCode
  attribute :box_number,  BoxNumber

  identified_by :branch_code, :box_number
end

aggregate "TransferInstruction" do
  identified_by do
    attribute :scheme,        PaymentScheme
    attribute :end_to_end_id, EndToEndIdentifier
  end
end
```

There must be no hidden interpretation where “many” means one, where identity names a field instead of a value concept, where Ruby and Rust concatenate different values, where a missing reference secretly means “create,” where behavioral `reference_to` hides a lookup, or where a child construct makes the caller repeat schema or facts already owned by its parent. Persistence remains a runtime byproduct, receiver identity remains routing rather than payload, relationships remain structural state, identities cross behavioral boundaries, and state-independent commands avoid unconditional read-before-write.
