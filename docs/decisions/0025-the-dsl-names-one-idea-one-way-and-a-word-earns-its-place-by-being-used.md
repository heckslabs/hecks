# The DSL names one idea one way, and a word earns its place by being used

**Status:** Accepted — partially implemented. Sequenced work plan at the
end of this document, but **read
[`docs/dsl-work-slices.md`](../dsl-work-slices.md) first** — it re-cuts
this plan into parallelizable slices (S0a-S13) and tracks real, current,
per-slice status against the code, which has moved since this ADR's text
was written (two corrections inline below: `has_many`/`has_one`/
`belongs_to` were kept, not deleted; `then_set`→`sets` already landed).
Trust that doc's status table over this one's prose before starting any
slice — this document records the *decision*, not a live status feed.

## Context

The language grew by accretion, and accretion has a signature: the same idea acquires a second spelling, a word outlives the reason it was added, and a rename lands on one side of a boundary but not the other. None of these announce themselves. Each one was a reasonable local decision, and the sum is a language that says the same thing several ways and says some things that aren't true.

A word-by-word review of the live surface — every reference page, checked against `syntax.bluebook`, the builders, the runtime, and the corpus — found five recurring shapes:

**One idea, several spellings.** `identified_by` had three (bare field, `ValueObject, as:`, and a block). `attribute`'s type position had three (bare constant, omitted-defaults-to-String, quoted text). `sets`/`then_set` and `report`/`read_model` each had two, from renames applied on one side only. `from:` was a pure synonym for `to:` that the language's own refusal message had already forgotten. Four relationship words — `reference_to`, `has_many`, `has_one`, `belongs_to` — compiled to one mechanism, and the reference page said so out loud: *"THREE WORDS, THREE FIELD NAMES, ONE MECHANISM."*

**Words that read as configuration and configure nothing.** `consistency`, `freshness`, and `use_index` are parsed, held in the IR, and read at runtime by exactly one thing — the HTML form renderer, which prints them as badges. No adapter honours any of them. Both corpus uses carry comments explaining behaviour that does not happen: *"Read against yesterday's close rather than blocking on whatever posted a second ago"* sits above a query that blocks exactly as before.

**Magic-string agreements the language never checks.** `emits "X"` and a policy's `on "X"` are two free strings with no check between them, in two different spellings (`emits` bare, policy `on` qualified by aggregate, process-manager `on` bare again). A policy listening for an event nobody emits loads cleanly, deploys, and silently never runs — verified by probe. The same is true of the 37 command-name strings in `trigger`/`dispatch`. This is not hypothetical: `"Account.Freeze"` survives in frozen era text where the live bluebook says `"Account.FreezeAccount"`. That policy was dead, shipped, and minted into an era; the reference-doctest work caught it, not the language.

**Prose that turns out to be load-bearing.** `role` and `goal` sit on adjacent lines in every command and read as a matched documentary pair. `goal` is documentation. `role` gates access control by exact string equality against `Caller.current.role` — eight distinct free-text values across 103 commands, no closed set, so `role "Branch Clerk"` with a capital C silently locks out every caller. Meanwhile the framework ships `Governance::RoleAssignment`, a real RBAC model with actors, scopes, and time bounds, connected to none of it.

**One vocabulary declared twice, already drifted.** The thirteen reading words shared by `query` and `read_model` are declared separately per context in `syntax.bluebook`, and the copies disagree: `where` fills `wheres` in one and `options` in the other; `order_by` fills `order_field`/`order_way` versus `field`/`direction`; `limit` fills `limit` versus `value`. The same shape recurs between `AggregateBuilder` and `EntityBuilder`, which each implement `identified_by` and its pending-identity resolution, and between the two state machines — `lifecycle`/`transition` on aggregates, `state`/`transition:` on process managers — which express trigger, from, and to in entirely different grammars.

## Decision

Four principles, and the decisions that follow from them.

### Principles

1. **One idea, one spelling.** Where two texts mean the same thing, the redundant one is refused, not merely discouraged. This is why `identified_by :"number.value"` is refused when `identified_by :number` already names it, and why `sets :number, to: :number` is refused when `sets :number` does.
2. **The DSL names a field where it could name a type.** Type names appear where a type is being declared, not where a field is being referred to.
3. **A word that reads as behaviour must be behaviour.** A word the runtime does not honour is a false statement in the model, and worse than a missing feature — a reader cannot tell it apart from one that works.
4. **A word earns its place by being used.** A word stays if it has a real corpus use *and* a running doctest. An external consumer outside this repo is a valid exemption from the corpus bar, written down and naming the consumer, never assumed.

### Identity

- `identified_by` **points at a declared field and never declares one.** `identified_by AccountNumber, as: :number` minted the attribute, which is the only reason the type name was there; remove the minting and the type name has no work to do. This also deletes `resolve_identity_type!`'s `attributes.insert(insert_at, attributes.pop)` reordering, a mechanism that existed solely because one word did two jobs.
- Composite identity is `identified_by :branch_code, :box_number`. The block form and the `ValueObject, as:` form both go.
- An identity head may be a **single-field value object** (auto-unwrapped), a **bare scalar**, or a **reference**. Multi-field value objects and lists are refused.

  The reason multi-field value objects are refused is Evans's, not aesthetic. Evans is categorical that identity must be unique and **must not change**; he is explicitly plural about identifying *attributes* and offers no support for "identity must be one scalar." Deriving identity from a multi-field value object makes it depend on the declaration order of that value object's members — and member order is free to change, which `ir.rb:41` already treats as a changed artifact. A cosmetic reorder would silently re-key every record ever written. A single-field value object has no order to change.
- **Cost found during review:** bare-scalar identity does not currently work. `AggregateBuilder` supports it (`attribute_collector.rb:121` returns `[field]` for a primitive) but the meta-validator refuses it — *"Identify refused — an identity part reaches a scalar."* The builder has a live code path the language rejects. This decision requires the validator to change too.

### References

- **`_id` is no longer minted.** `reference_to Account` produces `:account`.
- **Traversal gets its own operator.** `/` crosses into another record; `.` walks fields inside this one. `:"customer/status"` is a hop; `:"pizza.price_cents.cents"` is a field walk. Today both are spelled `.` and only the schema tells them apart.

  This is what makes dropping `_id` possible rather than merely desirable. `Naming.reference_hop` currently derives the traversal name from the field name — `account_id` donates `account` to the hop, and a field named `account` would force `account_account`. An explicit operator removes the derivation, and with it `HopPath.hop_head?`'s disambiguation rule (*"a real LOCAL attribute of that name wins first"*), which exists only to arbitrate the collision.
- On a `Handle`, **`piece.account` hydrates the record and `piece[:account]` reads the raw id.** The bracket form already reads as raw storage. This preserves today's hydrating accessor and moves only the id read.
- ~~**`has_many`, `has_one`, and `belongs_to` are deleted**, and nothing replaces them.~~ **Superseded (2026-08-27) — kept, not deleted.** All three were `reference_to` with a different minted name at the time this ADR was written, so deletion looked free. Since then, a separate slice (referenced in `spec/evolve_spec.rb:45-47` as "S17/ADR 0026's relationship-cardinality slice") deliberately un-deprecated all three — they build and dispatch for real today (`aggregate_builder.rb`/`entity_builder.rb`'s `has_many_impl`/`has_one_impl`/`belongs_to_impl`), not merely refuse outside `shadow_parse`. That's a real, working, presumably-relied-on part of the live DSL now, not dead syntax nobody got around to removing — deleting it would be a regression, not a cleanup. `has_many`'s original bug (`film.backers` singularising and reading `nil` instead of `[]`) needs verifying separately; if it still reproduces, fix it in place rather than deleting the construct.

  **What this changes for S2 (references, the sequenced-work-plan slice this decision lives under):** scope narrows to the `_id`-minting removal and the new `/` hop-traversal operator. `reference_to`, `has_many`, `has_one`, and `belongs_to` all stay as words; only the identity-suffix minting and the overloaded `.` traversal are what's actually being fixed. See `docs/dsl-work-slices.md`'s S2 entry, which should be read alongside this note before starting that slice.

  No one-to-many word is added. Owned `entity` declarations, `list_of` value fields, and the many side pointing back at the one side already cover every case in five domains — which is also the shape Vernon argues for, since a root holding a collection of foreign roots is the pattern to avoid.
- **The no-bidirectional rule becomes acyclic within a chapter.** Today `validate_no_bidirectional_references!` catches direct pairs only; `A → B → C → A` passes, and `hop_path.rb:11` records that as deliberate (*"explicitly declines to take a position on a longer ring"*). Self-reference stays legal — `parent.parent.name` for a hierarchy is real and safe. Cross-chapter rings are unreachable rather than unchecked: `Reference#resolve` is scoped to its own chapter by construction, so a cross-chapter reference is a dangling name, not an edge. If cross-domain references ever become resolvable edges, this rule has to move to a registry-wide phase.

### Attributes

- The type position takes a **bare constant, always required**. The `= String` default and the quoted-text form both go. No corpus attribute uses the default, and the quoted form is redundant for forward references — `ConstShim#const_missing` returns a Symbol for any bare constant, declared or not. Quoted types were only ever needed for *scoped* names, which is `admits:`'s problem, addressed below.
- **Closed sets lose the wrapper block.** A single-field set is an attribute keyword, joining `pattern:` and `admits:` where value constraints already live; a multi-field set is bare `member` lines.

  ```ruby
  value_object "AccountKind" do
    attribute :name, String, one_of: %w[current savings reserve]
  end

  value_object "Topping" do
    attribute :name,   String, pattern: '[^ \t\n\r]'
    attribute :amount, Integer

    member name: "mozzarella", amount: 2
    member name: "basil",      amount: 1
  end
  ```

  `one_of(…)` in the type position and `admits:` are unchanged. This also removes a documented landmine: the inline `one_of(…)` *cannot* be used inside a `value_object` block today, because it desugars onto the enclosing builder where a different `one_of` of different arity already lives.

  Pushing the keyword up to the value object itself (`value_object "AccountKind", one_of: %w[…]`) was rejected: it has to invent the field name, the three single-field sets in the corpus disagree about what that should be (`:value` twice, `:name` once), and a value object's field names *are* its stored shape — so it is a data migration across 73 call sites and six occurrences in frozen era text, bought for one line of source.

- **Addendum (2026-08-16): a single-field value object's bare-scalar auto-unwrap, generalized past identity.** Line 36 above scopes this to `identified_by`; it now holds everywhere a single-field value object is the declared type of an attribute — a command argument, a mutation source, a query argument. `size: "large"` and `size: { value: "large" }` both admit for a `Size { value }`-typed field, the wrapped spelling never required. Landed in `Value.for_attribute` → `fields_for` (`lib/hecks/runtime/value/coercion.rb`), the runtime's one door for coercing a raw caller value into a declared type — not a new door, so it inherits every existing refusal path unchanged: a genuinely multi-field value object still refuses a bare scalar, and a wrong scalar for a real single-field type (`Money.cents` given `"lots"`) still fails at that field's own numeric/pattern check, one level down. Also closed, alongside this: `Value.build` did not previously re-normalize a value object's own COMPOSITE-typed fields (a `Pizza` holding a `Price`) — a bare scalar or partial Hash for one of *those* sailed past `Pizza`'s own two-field shape check and landed stored exactly as handed in, one field short of the shape a dotted query path (`pizza.price_cents.cents`) expects. `Value.build` now takes the owning `aggregate` and recursively normalizes composite fields the same way, without turning a nested field into a `Value` instance — it stays the plain Hash every other reader already expects. Mirrored on the Rust/WASM side: `rust/project/json_codec.rb` and `rust/codegen/src/json_codec.rs` both wrap a bare JSON scalar into a single-field value object's own shape before calling that type's `from_json`, and `Fuzzing::ValueGenerator` now actually generates the bare-scalar shape sometimes, so an engine that drifts on it is caught rather than silently untested.

### Reads

- **`query` and `read_model` stay two concepts.** A query is a read against an aggregate through its own boundary; a read model is a separate denormalised projection with its own consistency story. They share thirteen reading words because reading is reading, and that vocabulary is **declared once**, with both contexts inheriting, instead of twice with drift. The grammar is a flat table with `context:` on every row, so a shared-context concept has to be added to `syntax.bluebook` itself.
- **`read_model` is the word, everywhere.** `report` is reverted. The IR construct, the registry API (`registry.bluebook(…).read_model(…)`), and the docs filename already say `read_model`, and so does every frozen era file — no era was ever minted under `report`, so this is history and source agreeing again rather than a migration.
- **`consistency`, `freshness`, and `use_index` are deleted.** None is honoured by any adapter; their mode symbols (`:eventual`, `:snapshot`, `:bounded`) appear nowhere in `lib/` and are unvalidated. Re-add when an adapter honours them, at which point `consistency` belongs on a query (isolation is a transaction concern) and `freshness` on a read model (lag is a projection concern).
- **Both paging mechanisms stay.** `limit`/`offset` and `cursor` are different mechanisms, not two spellings — positional versus keyset. Both are implemented in adapters; neither is exercised by the corpus, which is a coverage failure under principle 4 and not a reason to delete either. `cursor` becomes the documented default for paging a live aggregate store, and `offset`'s page-drift behaviour is stated in its reference page rather than left to be discovered.

### Commands

- ~~**`sets` everywhere.** The grammar already declares it with `was: "then_set"`; the corpus is 143 `then_set` and zero `sets`.~~ **Done, ahead of this ADR's own sequencing (verified 2026-08-27).** The corpus is now 119 `sets` and 1 `then_set` — the reverse of the count above, and that one surviving `then_set` is the deliberately-kept `deprecated` grammar row `spec/evolve_spec.rb:47-49` describes, refusing live and readable only via `shadow_parse`. `then_set` reads as sequencing, which is a promise the language does not keep — mutations are a declared set, not an ordered one.
- **`to:` is omittable when it is the identity, and the redundant form is refused.** All 35 `to:` mappings in live bluebooks are `x → x`. `sets :opening, to: :starting_balance` still spells a genuine remap. `increment:`, `decrement:`, and `append:` are unaffected — they name a genuinely different source.

  Inferring the mutation entirely from a declared attribute was rejected: a command attribute that feeds only a `given` (`Debit`'s `amount`, guarding the balance) would silently start writing a field.
- **`from:` is deleted** — a pure synonym for `to:`, zero uses, already absent from the language's own refusal message. `multiply:`, `clamp:`, and `remove:` stay under the principle-4 exemption, naming `plan.bluebook`'s `RemoveDependency`/`DeactivateSprint` as the consumer, and gain corpus examples.
- **`MutationApplier#apply` gains an `else raise`.** Every declared op has a `when` today, so nothing silently no-ops — but an op added to the grammar without a handler would apply nothing and refuse nothing.
- **`role` becomes real RBAC, or it is refused.** A command declaring `role` in a hecksagon that does not `uses_framework "Governance"` is `Malformed`. With Governance attached, `role` names a `Governance::RoleName` and is checked against the caller's active `RoleAssignment`s — many roles, scoped, time-bounded — rather than by string equality against a single `caller.role`.

  Silently downgrading `role` to documentation when Governance is absent was rejected: an authorization check that runs today would stop running with nothing anywhere saying so, which is the `consistency`/`freshness` defect applied to access control, failing open.

### Events and reactions

- **Events become first-class, with declared payloads.** In DDD a domain event is a value object with its own attributes, not a label. The name being unchecked is the cheap half of the problem; `with: { account: :account }` projecting into a reaction that has no declared contract is the expensive half, where a rename on either side breaks at dispatch rather than at load.
- **Command references become first-class.** A command is already a declared thing, so `trigger AccountFreezeReview::Open` and `dispatch Account::Debit` name it as one. This also collapses the qualified/unqualified split between policy strings (`"Account.Freeze"`) and saga strings (`"Banking::Account.Debit"`).
- **One state-machine vocabulary, the aggregate's.** A saga transition reads the same shape as a lifecycle one, differing only in what triggers it — a command on one side, an event on the other, which is the honest difference:

  ```ruby
  process_manager "Settlement" do
    correlates_by :"reference.value"

    transition AccountDebited => "awaiting_credit", from: "requested" do
      dispatch Account::Debit, with: { number: :source, amount: :amount }
    end
  end
  ```

  ~~`state`, `transition:`, `starts_on`, and `ends_on` are retired; states are whatever the transitions name, exactly as on an aggregate, and the first and terminal states carry what `starts_on`/`ends_on` said.~~ **Amended (2026-08-27) — `starts_on`/`ends_on` kept, not retired.** `state`/`transition:` are gone: every process manager in the corpus now uses the `transition EVENT => "state", from: "prior"` shape shown above, states derived from the transition graph (`ProcessManagerBuilder#derived_states`), exactly as this section originally specified. `starts_on`/`ends_on` were checked against the real corpus rather than assumed away, and deliberately kept: `Settlement`'s own `ends_on "TransferSettled"` names an event NONE of its own transitions handle (`Transfer.Settle`'s emission is a step downstream of the transition that dispatches it) — "the terminal state's own event" is not a fact the transition graph carries for this real corpus member, so deriving it would either be wrong here or need a second new word, which is not less vocabulary than keeping the one that already says it correctly. See `ProcessManagerBuilder`'s own header comment for the full reasoning. The event-trigger-as-bare-constant form shown in the example above (`AccountDebited =>`, not `"AccountDebited" =>`) is NOT yet live — it depends on events being first-class with a real resolvable constant (this section's own first bullet, "Events become first-class, with declared payloads"), which is still open; today's corpus correctly uses quoted event names on the trigger side (`transition "AccountDebited" => ...`) until that lands. Command references on the dispatch side ARE already first-class (`dispatch Account::Debit`, bare constant, refused as quoted text outside `shadow_parse`).

### Aggregates and entities

- **One vocabulary, two words.** `entity` declares the seven root words (`description`, `identified_by`, `attribute`, `reference_to`, `command`, `query`, `lifecycle`); `aggregate` is an entity plus the boundary words (`value_object`, `policy`, `entity`). `EntityBuilder`'s duplicate `identified_by` and `resolve_pending_identity!` go.

  This makes true in the implementation what DDD says and what the codebase's own vocabulary already assumes — Evans has you choose one Entity as the **root** of each Aggregate, and this code has said `identity_heads` and *"references must target aggregate heads"* all along. Sharing the vocabulary does not share the addressing: a piece is still reached only through its root (`Banking::Account.LedgerEntry.Reverse`, carrying both identities), because that is `EntityInterpreter`'s doing, not the vocabulary's — its `instance` is the parent aggregate record, it inherits the aggregate's argument gate, and an entity is never created through it.

  An explicit `head do … end` block was rejected: it adds a nesting level to every aggregate to make explicit something the language never lets you get wrong, since you cannot declare two heads.

### Rules — invariants, preconditions, postconditions

- **Aggregates gain `invariant`**, checked after every command before `save`, the same way a value object's already is. Today `invariant` exists only inside `value_object`, so an aggregate-level rule has nowhere to live.

  In DDD an aggregate boundary exists precisely to be the scope inside which a set of rules holds after every transaction — invariants are what *define* an aggregate. A language for DDD whose aggregates cannot state one is missing the thing aggregates are for, and the corpus shows the cost. Six `Account` commands move `:balance`, and "the balance never goes negative" is expressed three ways: `Debit` states it as both a `given` and an `ensures`, `ApplyFee` as a differently-worded `given`, and the four commands that only increase a balance say nothing at all. Completeness depends on someone noticing which commands can decrease a balance; add a seventh and nothing reminds you.
- **An invariant guards writes, not history.** A record stored before an invariant was declared loads normally; the first command against it refuses. Verifying at boot would make boot time scale with stored data and would make an existing record un-inspectable and un-correctable. Treating a new invariant as an era shape change was also rejected — `EraGuard::ShapeDiff` compares *shape*, and an invariant is a predicate over values, so making it a shape change would turn every predicate edit into a migration. A separate on-demand sweep answers "which stored records would refuse their next write" deliberately, rather than leaving it to be discovered.
- **The `ensures`/`invariant` boundary is documented, not policed.** An `ensures` that never mentions `old` is not thereby an invariant — `ensures("the account is closed") { status == "closed" }` on `CloseAccount` is a legitimate command-specific postcondition. `old` distinguishes relational postconditions from absolute ones; it does not distinguish postconditions from invariants, and "does this hold after every command" is a claim about commands that don't exist yet. Refusing duplicate `ensures` text was also rejected — it is defeated by rewording, which the corpus already does (*"the balance covers it"* and *"the balance covers a fee"* are one rule in two sentences).

  The three words then split cleanly: **`invariant`** always true, **`given`** true before, **`ensures`** relates before to after.
- **Lifecycle state becomes a command guard.** `command "Debit", from: "open"` replaces `given("account is open")`, written 35 times in two wordings — and since the description *is* the refusal message, a caller currently sees a different sentence depending on which command they hit. The lifecycle already declares which states exist, so a command naming its legal states is checkable against it, where a free-text `given` can drift out of sync with the state machine and did.
- **A precondition shared across commands is declared once.** An aggregate declares it by name and commands reference it, so there is one description and therefore one refusal message. The top two rules account for 44% of all 183 givens in the corpus.

### Consistency across aggregate boundaries

- **A rule may only read within its own aggregate boundary.** A `given`, `ensures`, or `invariant` may read the aggregate's own attributes, its projected fields, its command arguments, and — for an entity — `parent`, which is inside the boundary. It may **not** read through a `reference_to`. `References#dereference` is deleted outright, and with it the 4-deep eager read, `DEREFERENCE_DEPTH`, and the aliased-reference merge-order subtlety a fuzzer found a `TypeError` in.

  This is Evans's own line, not an extrapolation: apply consistency rules synchronously **within** an aggregate boundary, and handle updates across aggregates asynchronously — *"any rule that spans AGGREGATES will not be expected to be up to date at all times."* Forty-five preconditions in the corpus (`given("customer is active")`) are exactly such a rule, read transactionally.

  Query hops are unaffected. ~~`dereference`'s only two call sites are `enforce_givens` and `enforce_ensures`~~ **Stale as of S10 (2026-08-27)** — aggregate `invariant` didn't exist when this line was written; now that it does (S10, this same ADR), `dereference` has two more call sites, `enforce_invariants` and `check_entity_invariants` (`command_rules/admissibility.rb`), both reachable the same way `enforce_givens`/`enforce_ensures` are. The boundary rule still applies to them identically — an invariant may not read through a `reference_to` either — this just widens where the deletion has to reach. Queries still traverse through `HopPath` and keep doing so.
- **Cross-aggregate state is declared as a projection**, and the language knows it is a copy:

  ```ruby
  aggregate "Account" do
    reference_to Customer
    projects :customer_status, from: Customer, field: :status
  end
  ```

  The reaction that maintains it is generated rather than hand-written. A projected field is not an ordinary attribute: it is refused as an identity head (it changes, and identity must not), no command may `sets` it, it is regenerable after drift, and it reads as derived in the generated docs and forms rather than as a fact the aggregate owns. A hand-rolled attribute plus a hand-written policy was rejected because every one of those properties would be convention, and drift between copy and source is silent.

- **A projection is backfilled by a rebuild, and an unpopulated one refuses distinctly.** There is no existing backfill path to inherit, and the gap is worse than absent — it is silently wrong:

  - Adding an attribute requires no translation. `uncovered_attributes` iterates the *held* shape looking for fields that vanished or changed type (`shape_diff.rb:38`), so a newly added attribute is never uncovered and `EraGuard` never refuses one. Existing records simply lack it.
  - `compute` cannot create a field from nothing — it refuses without a source path — and is SQL-only and Postgres-only by its own comment, so Memory, SQLite, D1, and Heki have no equivalent.
  - `GuardState` deliberately reads a declared-but-storage-absent attribute as `nil` rather than "cannot resolve" (`admissibility.rb:17`). So on an existing record `customer_status` is `nil`, `nil == "active"` is false, and **every command refuses with `GivenNotMet: customer is active` on a record whose customer is active** — pointing away from the cause.

  Therefore: a `projects` field is **regenerable from its source through the repositories**, adapter-agnostic rather than SQL, run on demand and when the declaration first appears — the same operation drift recovery needs, so it is built once. And an unpopulated projection raises **`ProjectionAbsent`**, because a projection that has never run is *unknown*, not *not-"active"*; letting `nil` read as a legitimate value is the same silent-wrong-answer class as the `ne:`-with-empty-string and array-`in:` query bugs. Extending `compute` instead was rejected: it would make projections Postgres-only, and with them the whole cross-boundary rule.

**The costs of this decision, recorded rather than argued away.** Cross-aggregate reads are currently *consistent*, because dispatch runs a command's mutation, emission, policy reaction, and saga advance synchronously in one call. Replacing them with projections makes those checks eventually consistent, so `given("customer is active")` can pass for a customer suspended moments earlier. The framework also does not avoid locks: every append takes `pg_advisory_xact_lock(hashtext('hecks_ordinal:' || domain))` for the whole transaction — a **domain-wide** write lock, coarser than row locks — so each maintaining reaction is another write through that same serialisation point. What is avoided is read locks: the dereference happens before the transaction opens. This decision therefore trades consistent reads for more writes through a domain-wide lock, deliberately, in exchange for aggregates whose rules are answerable inside their own boundaries.

### Added attributes and absence

Adding an attribute to an aggregate is free today — `EraGuard` reads only the *held* shape, so nothing demands a translation — and a record written before the field existed simply lacks it. That is safe in three of four cases, and silently wrong in the fourth:

| new attribute | on an existing record | |
|---|---|---|
| has `default:` | filled | safe |
| is `list_of(...)` | frozen `[]` | safe |
| a value object whose fields **all** have defaults | built from `{}` | safe |
| anything else | **absent** | unsafe |

- **`EraGuard` demands a translation when a newly added attribute could be absent** — non-optional, no default, not a list, not a fully-defaulted value object. Only the fourth row; the other three stay free. This is the same refuse-at-declaration posture the guard already takes for vanished and retyped fields, reading the current shape as well as the held one.
- **Absence, if it happens anyway, is unknown rather than `nil`.** An **optional** attribute that is absent reads `nil` — that is what optional means. A **non-optional** attribute that is absent raises a named refusal identifying the field and the reason, rather than letting a predicate evaluate against a value nobody wrote.

  This resolves a tension between two existing behaviours built for opposite reasons. `GuardState`'s nil-read was a fix: a real `Item.Promote` crashed on `!promoted` against a record predating the field, so absence was made to read as `nil` instead of "cannot resolve" (`admissibility.rb:11-16`). That same nil-read is what makes an unpopulated projection answer "not active." The comment names the case it was fixing precisely — *"reading an **optional** field a record predates"* — and restricting the nil-read to optional attributes keeps that fix while closing the hole. A named refusal is also strictly better than what the nil-read replaced: the crash becomes a message that says what happened.

The rule catches what can be predicted at declaration; the refusal catches what it cannot — state written outside the framework, or a record restored from a backup taken before the field existed.

### Mechanism

- **A scoped-constant bridge.** Facade-installed modules answer `const_missing` while `ConstShim.active?`. Verified necessary by probe: once a facade exists, `Widget` is a real module, so `Widget::Make` hits the default `Module#const_missing` and raises — the shim is never reached, exactly as `const_shim.rb:20` predicted. Without this, first-class events and first-class command references cannot be spelled as constants.

  This is the same blocker that forces `admits:` to be text, so the bridge also lets `admits: Account::LedgerDirection` replace `admits: "Account::LedgerDirection"` — the language's one text-typed reference.
- **Frozen era text is read by a legacy grammar.** `shadow_parse` is a plain `Kernel.eval` of stored source against the live DSL, run on every held era at boot, at mint, and during tamper detection; the text is SHA-256-locked against `held_digest`. Removed spellings therefore stay executable **only** when parsing held text, never in live source. Rewriting era files to the new spelling was rejected despite `bin/reattest_era` supporting it: `held_digest` means *this is the text that was running when that data was written*, and re-spelling it makes that false in exchange for tidiness in files nobody hand-writes.

### Coverage standard

A word stays if it has a **real corpus use** and a **running doctest**. An external consumer is a written exemption from the corpus bar, naming the consumer.

The doctest bar alone is what let the inert words through — `consistency` had a running example demonstrating it being *declared*, which is precisely the thing not in question.

A domain is more than its `.bluebook`: ports are declared in `.hecksagon` and realms in `.world`, so the corpus bar has to be measured across all three file types. Counted that way, **`port` (4), `operation` (1), `asks` (2), `answers` (3), `refuses` (6), `world` (3) and `realm` (3) all pass** — pizzas' `PaymentGateway.Receive` exercises the port vocabulary for real. Eleven words fail:

| group | words | remedy |
|---|---|---|
| paging and query options | `offset` `cursor` `nulls` `inspect_query` | corpus use |
| port vocabulary not reached | `tells` `verb` | corpus use, or exemption |
| worlds | `latest` | corpus use, or exemption |
| hecksagon | `subscribe` | corpus use, or exemption |
| classification | `generic` | corpus use |
| rename | `formerly_known_as` | exemption — used on Embryonaut → EmbryonautFoundersApp |

All eleven are implemented, unlike the three inert words. This is under-exercise, not vaporware.

`domain_port` is a further instance of the `report`/`read_model` split: the DSL word is `port`, declared on an aggregate inside a hecksagon, while the construct, the reference page, and the IR all say `domain_port`. It should be resolved the same way — one name, and the corpus already votes for `port`.

**A related instance, out of this ADR's own scope, worth naming so it isn't lost.** This review is scoped to the DSL surface a domain author writes — `.bluebook`/`.hecksagon`/`.world` — not the Ruby codebase's own internal vocabulary. But the identical anti-pattern this ADR exists to fix (one word, several unrelated meanings) is live in that internal vocabulary too: "projection" names six distinct things across the codebase — three related-but-formally-distinct senses documented in `lib/hecks/projector.rb`'s own opening taxonomy (a description-only projection, an export that carries a running system, and a state projection/read-model), plus `Ports::Projection` (read-model catch-up), `bin/project` (forces that catch-up), and `RustProjection` (a separate toolchain under a confusingly identical module name). `projector.rb`'s header already documents the collision; nothing yet renames any side of it. Not itemized above because none of these six are spelled by a domain author — but the same coverage standard this ADR applies to the DSL (one name per idea, remedy named per surviving word) is the right standard to eventually hold this to as well, likely as its own follow-on pass rather than folded into the DSL migration this ADR sequences.

## Consequences

- **Every removal depends on the legacy-grammar split.** Nothing can be deleted from the live DSL until `shadow_parse` can still read history, so that is the first commit and a hard prerequisite for most of the rest.
- **Three decisions depend on the scoped-constant bridge** — first-class events, first-class command references, and un-texting `admits:`. It is the second commit for that reason. The risk to test is a real facade method colliding with a declaration-time constant; the shim is only active during declaration, but the scenario that broke the earlier attempt was two domains in one registry, so that is the test to write.
- **A live adapter disagreement was found and FIXED ahead of this work** (`query_specification/common/null_policy.rb`, `common/comparison.rb`, `ports/query/in_memory.rb`, `runtime/query_interpreter.rb`, `bluebook/dsl/aggregate_builder.rb`; suite green at 1563 examples). The same bluebook, data, and query answered differently on two adapters:

  ```
  Memory  where(:"tag.value" => { ne: "red" })  ->  ["w2", "w3"]   # Ruby: nil != "red" is true
  SQLite  where(:"tag.value" => { ne: "red" })  ->  ["w2"]         # SQL:  NULL <> 'red' is NULL
  ```

  `sql_query_builder.rb:33` maps `ne` to `<>` with no null handling. **Resolved toward SQL's three-valued logic: a null matches no comparison**, and `Ports::Query::InMemory` changes to agree. That is the same rule as the absence decision above — unknown is not a value, and a comparison against unknown is unknown rather than true — so the two are one idea applied in two places, not a convention borrowed from SQL. Compiling `ne:` to `(col <> 'red' OR col IS NULL)` was rejected: it is more SQL to get right in two dialects, it reliably loses an index, and it bends a real query engine to match an in-memory adapter that exists for tests and small domains.

  This is the third instance of this bug class, after `ne:` with an empty string and array `in:`. The **adapter-agreement gate does not cover nullable comparisons** — that gap is what let all three through, and closing it matters more than any individual fix. Still open.

- **A second, latent divergence was found in the same place and fixed with it: there were three readings of "compare a value object as a scalar."** `in_memory` took the *first* numeric member, `query_interpreter` unwrapped only when there was *exactly one*, and `SqlQueryBuilder#query_value` took the first numeric then fell back to `hash[:value]` by name. The three agree for `Money { cents, currency }` and any single-member value object — which is why nothing caught it — and diverge for a value object with two numeric members, where one path compares a number and another compares a whole Hash.

  Resolved by refusing the ambiguity **at declaration**: a bare query field naming a value object with no single member a comparison could mean is now `Malformed`, naming the candidates and the dotted form (`AggregateBuilder#refuse_ambiguous_comparison!`). The dotted case was already refused when it landed on a value object rather than a scalar; the bare case returned unconditionally. Unambiguous stays unambiguous — exactly one member, or exactly one numeric among several, which is the reading every engine already shared and the corpus relies on.

  The two duplicated comparator tables — `Ports::Query::InMemory#holds?` and `Runtime::QueryInterpreter#holds?`, along with `comparable`, `ordered?`, `members`, `contains?`, `none_in_state?` and `find_aggregate_by_name` — are now one module, `QuerySpecification::Common::Comparison`. Each caller keeps only how it *reaches* a value (registry as argument versus instance state). That duplication had already cost two bugs by the codebase's own record: `none_in_state` reached one copy only and silently excluded every row, and `comparable` drifted as above.
- **Two latent defects were found and should be fixed with the work that touches them.** `hop_path.rb:191` asserts *"an entity has no `reference_to` at all"* as structural and skips hop deferral on that basis, while `EntityBuilder#reference_to` exists and works — an entity that used it would break the assumption. And `Domain::Aggregate.X.Y` is ambiguous between an entity command and a port operation (`dispatcher.rb:67`); nothing exercises it today because no bluebook declares a port, but the ambiguity is live in the verb space.
- **The `parent` word is undocumented.** A piece reaches its aggregate through `parent` (`given("account is open") { parent.status == "open" }`) and it appears in no reference page. It needs one under principle 4.
- **Both runtimes move together.** The Rust parser has its own fixture corpus (`rust/parser/tests/fixtures/`) and the kernel compiles the same constructs, so grammar changes are not Ruby-only.
- **The generated reference regenerates from `syntax.bluebook`.** Prose between the generated markers is hand-written and survives, so each concept's commit carries its own doc prose rather than deferring documentation to the end.

## Sequenced work plan

One ADR, then one commit per concept, each moving grammar, runtime, corpus, and docs together and green at every step. Layer-by-layer sequencing (all grammar, then all runtime) was rejected: it leaves the tree red between layers and makes bisect useless, which defeats the pre-push doctest gate.

| # | commit | depends on | notes |
|---|---|---|---|
| 0 | `shadow_parse` legacy grammar | — | prerequisite for every removal |
| 1 | scoped-constant bridge | — | unlocks 7, 8, and `admits:` |
| 2 | identity | 0 | includes the meta-validator fix for bare-scalar heads |
| 3 | references — no `_id`, `/` hop operator, handle accessors, delete `has_*`, acyclic rule | 0 | largest corpus churn: 243 `reference_to` sites, every dispatch call, every hop path |
| 4 | attributes — type position, closed sets | 0 | source-only; no stored shape moves |
| 5 | reads — `read_model` revert, shared reading vocabulary, delete the inert three | 0 | shared-context concept added to `syntax.bluebook` |
| 6 | commands — `sets` rename, omittable `to:`, delete `from:`, `else raise` | 0 | 143 + 35 call sites, mechanical |
| 7 | events first-class with payloads | 0, 1 | largest design change; touches `emits`, `on`, `trigger`, `with:`, saga `dispatch` |
| 8 | reactions — one state-machine vocabulary, first-class command references | 0, 1, 7 | five process managers rewrite |
| 9 | `role` → Governance RBAC | 0 | security-affecting; add the new check before removing the old |
| 10 | entity/aggregate shared vocabulary | 0 | also fixes the `hop_path.rb:191` assumption |
| 11 | rules — aggregate `invariant`, lifecycle state guards, named preconditions | 0, 10 | removes 35 `"account is open"` givens and dedups the rest |
| 12 | added-attribute absence — `EraGuard` demands a translation where absence is possible; named refusal as the backstop | 0 | independent of projections; closes a hole that already exists |
| 13 | `projects`, and rules confined to their own boundary | 0, 7, 8, 11, 12 | deletes `dereference`; 49 givens migrate; carries its own adapter-agnostic rebuild and `ProjectionAbsent` — no existing backfill path to inherit |
| 14 | coverage standard — corpus uses and written exemptions for the eighteen | all | closes principle 4 |

## Rejected alternatives

- **Deprecate rather than delete.** Rejected because a language whose selling point is refusing what it cannot check is undermined by words that half-work, and because the doctest gate makes a breaking change loud rather than silent. The legacy-grammar split gives history what a deprecation window would have given it, without leaving two spellings live.
- **Merge `query` into `read_model`.** Rejected — they are different concepts in DDD and in this runtime, and merging would repeat the `has_many` mistake in reverse by giving two genuinely different things one spelling. The duplication was in the vocabulary's *declaration*, not in the concepts.
- **Infer mutations from command attributes, and infer identity field names from type names.** Both rejected as the language guessing. Every constant-form `identified_by` in the corpus uses `as:` to give the field a name different from its type — twelve of twelve — so inference there is not a spelling change but a rename of every identity field and every dispatch payload.
- **Delete `multiply:`/`clamp:`/`remove:` and the port and world vocabularies for being unused here.** Rejected — they are implemented, spec'd, and have consumers outside this repo. Principle 4's exemption exists for exactly this, and requiring it to be written down is what keeps "unused" from silently meaning "dead."
