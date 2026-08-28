# DSL work slices

The work decided in [ADR 0025](decisions/0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md) and [ADR 0026](decisions/0026-the-language-uses-everything-it-declares-and-what-it-does-not-use-is-a-sub-language.md), re-cut from a sequence into slices that can be worked in parallel by separate agents.

Both ADRs sequence for one worker, with the prerequisites front-loaded. That ordering is still correct about *dependencies*, but it says nothing about *collisions*, which is what actually decides whether two agents can run at once.

## How to run a slice

**One worktree per slice.** Every slice edits `lib/hecks/language/bluebook/syntax.bluebook`, so slices sharing a checkout will trip over each other. Use `isolation: "worktree"`.

**A slice is vertical.** It is not done until all six of these move together:

1. the grammar rows in `syntax.bluebook` for the words it owns
2. the builder(s) that read those words
3. the runtime that acts on them
4. every corpus call site — `examples/`, `lib/hecks/framework/`, `spec/fixtures/`
5. the hand-written prose in `docs/implemented/reference/*.md` (the generated regions regenerate; the prose between markers does not)
6. specs, including one that sees each new refusal *fail*

**Done means the gate passes**, not that the tests you wrote pass:

```
bundle exec rspec              # 1691 with CI=true, 1563 without
./bin/model_check
./bin/doc_coverage
./bin/fuzz --seeds 3 --steps 8
```

`bin/doc_coverage` is the one that catches an unfinished slice: remove a word without removing its reference section, or add one without an example, and it refuses.

## The shared-file rule

`syntax.bluebook` is 960 lines and partitioned into contiguous runs by `context:` — Aggregate 15 rows, Query 14, ReadModel 17, Command 8, Entity 8, Policy 5, ProcessManager 6, and so on. Two slices touching different contexts touch different regions, so conflicts are textual and mechanical rather than semantic.

The exception worth knowing: **`attribute` rows appear under Aggregate, Entity, and Command**. Any slice changing the attribute vocabulary touches three regions and will conflict with the slices that own those contexts. That is why S3 is sequenced alone.

## Wave 0 — prerequisites

These two block most of what follows and are independent of each other, so run them together.

### S0a — `shadow_parse` reads a legacy grammar — DONE, verified 2026-08-27

**Why first:** frozen era text is parsed by the *live* DSL — `shadow_parse` is a plain `Kernel.eval` run at boot, at mint, and during tamper detection, and the text is SHA-256-locked to `held_digest`. **No word can be removed until history can still be read.**

**Owns:** `runtime/era_guard.rb`, `bluebook/meta_validator.rb`, whatever flag the builders consult.
**Blocks:** S1, S3, S4, S5 — every slice that deletes a spelling.
**Done when:** a bluebook using `identified_by { number.value }` refuses in live source and parses in `shadow_parse`, with a spec covering both directions.

### S0b — the scoped-constant bridge — DONE, verified 2026-08-27

**Why first:** verified by probe — once a facade exists, `Widget` is a real module, so `Widget::Make` hits the default `Module#const_missing` and the shim is never reached. Without this, first-class events and command references cannot be spelled as constants at all.

**Owns:** `facade/surface.rb`, `bluebook/dsl/const_shim.rb`.
**Blocks:** S6, S7, and the `admits:` half of S3.
**Watch:** the scenario that broke the earlier attempt was two domains in one registry. Write that test first.
**Done when:** `Account::Debit` and `admits: Account::LedgerDirection` both resolve during declaration, and a real facade method with a colliding name still works.

## Wave 1 — parallel, no shared context

| slice | owns | corpus blast radius |
|---|---|---|
| ~~**S1 — identity**~~ | ~~`identified_by` rows (Aggregate, Entity); `attribute_collector.rb`, `aggregate_builder.rb`, `entity_builder.rb`, meta-validator identity judge~~ | **DONE, verified 2026-08-27.** `identified_by_impl` (`identity_declaration.rb`) is one collapsed form; the old block form routes through `legacy_identified_by` only during `MetaValidator.shadow_parsing?`. Zero `as:`-form declarations left anywhere in the live corpus. |
| ~~**S2 — references**~~ | ~~`reference_to` rows (Aggregate, Entity); `naming.rb`, `hop_path.rb`, `handle.rb`, `query_interpreter.rb`, `sql_query_builder.rb`, `bluebook_builder.rb`~~ | **DONE, verified 2026-08-27.** `_id`-minting removal (`attribute_collector.rb`'s `default_reference_name`), the `/` hop operator (`hop_path.rb`'s `hop_head?`/`next_hop`), the `Handle` accessor split (`handle.rb`), and acyclic-cycle detection widened from direct pairs to a full DFS (`bluebook_builder.rb`'s `validate_no_bidirectional_references!`) were all already shipped. Fixed one stale comment and added real N-node-ring test coverage (every prior cycle spec was a 2-node ring, which the OLD direct-pair check already caught — nothing proved the widening). `has_many`/`has_one`/`belongs_to` stay, per the amendment above — not part of this slice's scope. |
| ~~**S4 — reads**~~ | ~~Query + ReadModel rows; `query_builder.rb`, `read_model_builder.rb`~~ | **DONE, verified 2026-08-27.** No live `report` DSL method anywhere in `bluebook/dsl/`; `consistency`/`freshness`/`use_index` absent from `syntax.bluebook` entirely. |
| ~~**S5 — commands**~~ | ~~Command rows; `command_builder.rb`, `mutation_applier.rb`~~ | **DONE, verified 2026-08-27.** Corpus is 119 `sets` / 1 `then_set` (the deliberately-kept deprecated row); `from:` absent from the corpus entirely; `sets :target, to: :target` self-mapping is refused (`command_builder.rb:277-281`); `MutationApplier#apply` has its `else raise Runtime::WiringError` guard (`mutation_applier.rb:94`). This table's own count was stale — check the live code before trusting either this row or the ADR text's count. |
| ~~**S8 — role → Governance**~~ | ~~`role` row (Command); `command_rules/authorization.rb`, `hecksagon_builder.rb`~~ | **DONE, verified 2026-08-27.** `Authorization#refuse_role_mismatch` (`command_rules/authorization.rb:27-61`) checks an identified caller's real `Governance::RoleAssignment` via `Ports::Authorization.holds_role?`, never falling back to string equality once identified. `Verification#refuse_ungoverned_roles!` (`registry/verification.rb:132-147`) refuses any domain declaring `role` without `uses_framework "Governance"` at load time. Scoped/time-bounded revocation and the ungoverned-refusal live specs both pass (`spec/act_as_spec.rb`, `spec/environment_overlay_spec.rb`). |
| **S11 — absence** | `era_guard/shape_diff.rb`, `command_rules/admissibility.rb` (`GuardState`) | none — pure runtime |

**S1, S2, S4, S5, S8, S11 can all run at once.** S2 is the one to start earliest regardless of who takes it: 243 call sites means it will finish last whatever else happens.

S8 is security-affecting — **add the new check before removing the old one**, and land it behind its own commit so it can be reverted alone.

## Wave 2 — depends on Wave 1

| slice | depends on | note |
|---|---|---|
| ~~**S3 — attributes**~~ (type position, closed sets) | S0a | **DONE, verified 2026-08-27.** `attribute_impl` (`attribute_collector.rb:61`) takes `type = UNSET` (no default-to-String) and explicitly refuses a quoted-text type ("give the bare constant instead"). `one_of:` is a direct kwarg on `attribute_impl`, 14 corpus uses of the inline single-field form. |
| ~~**S6 — events first-class**~~ | S0a, S0b | **DONE, verified 2026-08-28.** `emits`/policy `on`/saga `transition` triggers all accept a bare constant (`Naming.event_ref`) or the old quoted string. Corpus migration complete: 136 `emits`/`on` sites now bare-constant across `examples/`, `lib/hecks/framework/bluebook/`, and the self-hosted language's own grammar bluebooks; the last 2 quoted sites (`examples/pizzas/{pizzas_behaviors.hecksagon,bluebook/pizzas.hecksagon}`, both `PaymentGateway` port operation's `emits "PizzaPaymentReceived"`) are a deliberately different grammar context — `PortOperation#emits` (`port_operation.bluebook`) is declared `kind: "text"`, not `kind: "constant"`; it names the boundary translation of an external fact into domain vocabulary, not a reference to an already-declared aggregate event, so it was never in S6's scope (which covers `emits`/`on`/saga-transition triggers on aggregate-declared events). `starts_on`/`ends_on` (S7's own remaining piece, below) also fully migrated to bare constants this pass: added `starts_on_impl`/`ends_on_impl` (`process_manager_builder.rb`), a new `Naming.event_name_ref` (keeps only the final bare segment of a qualified event constant, distinct from `event_ref`'s dotted-qualifier-preserving form — needed because `SagaInterpreter#advance_saga` matches `handler.event_type` against a bare `event.name`), extended both the Ruby grammar (`process_manager.bluebook`) and the Rust parser (`rust/parser/src/{build/naming.rs,keywords.rs,parse/mod.rs,parse/process_manager.rs}`) to accept bare constants there. Old quoted spelling still accepted everywhere (not refused) — a corpus-migration slice, not a refusal decision; refusing the legacy spelling remains a separate, undecided design call. `with:` checking already works via shape-inference from the emitting command (`event_shape_for`/`check_with_spec!` — pre-existing), which turned out to be what the ADR's with:-checking goal actually needed; a separate declared `event` block with its own attributes was judged unnecessary for that but may still be wanted for the ADR's DDD framing — a design call, not decided here. Gate: full rspec (2297/2297), model_check 0 errors, doc_coverage clean, rubocop 656 files/0 offenses, parser_parity 40/40, codegen_parity 8/8, real `cargo build` + `cargo test --lib` (68/68), rust_conformance_spec 14/22 (unchanged pre-existing Rust-runtime-projection-gap baseline) — all green. |
| ~~**S10 — rules**~~ (aggregate `invariant`, lifecycle guards, named preconditions) | S0a, S9 | **DONE, verified 2026-08-27.** Aggregate `invariant_impl` (`aggregate_builder.rb:409`) and the named-precondition mechanism (`declared_by:`, already applied to "customer is active"/"account is open") were already done. Migrated the remaining 30 commands across 7 files whose `given` duplicated a lifecycle-guarded check to `from:`/rely on the existing `transition`. Full gate green (2239). |
| ~~**S9 — entity/aggregate shared vocabulary**~~ | S0a | **DONE, verified 2026-08-27.** `EntityBuilder` includes the same `AttributeCollector`/`IdentityDeclaration`/`RuleReference`/`WordGate` modules `AggregateBuilder` does — zero duplicate `identified_by` in `entity_builder.rb`. The `hop_path.rb:191` line this row originally cited no longer matches current line numbers (file has moved on); not independently re-checked whether that specific old assumption survives elsewhere. |

## Wave 3 — depends on Wave 2

| slice | depends on |
|---|---|
| ~~**S7 — reactions**~~ (one state-machine vocabulary, first-class command refs) | S0a, S0b, S6 | **DONE, verified 2026-08-28.** `starts_on`/`ends_on` are a deliberate, correct keep, not an oversight: `Settlement`'s `ends_on "TransferSettled"` names an event none of its own transitions handle, so deriving it from the transition graph would be wrong for this real corpus member — see the ADR's own amended text. States ARE already derived from `transition` everywhere else (`ProcessManagerBuilder#derived_states`); old `state`/`transition:` forms are gone. Command references are already first-class (`dispatch Account::Debit`). The one remaining piece — event triggers as bare constants (`transition AccountDebited => ..., starts_on Order::Placed, ends_on Settlement::Cleared`) instead of quoted strings — landed with S6: all 6 corpus `starts_on`/`ends_on` sites now bare-constant, 0 remaining quoted. No longer blocked on anything. |
| ~~**S12 — `projects` and the boundary rule**~~ | S0a, S6, S7, S10, S11 | **DONE, verified 2026-08-28.** Boundary confinement landed: `enforce_givens`/`enforce_ensures`/`enforce_invariants`/`check_entity_invariants` no longer call `dereference(domain, owner, subject)` on stored state — only `dereference(domain, command, args)` (command-argument reads) remains. Banking's real cross-boundary `given`s (Account/SafeDepositBox/OnboardingCase/ATMCard/CardPayment/Statement/LedgerEntry) migrated to `projects` fields, each seeded synchronously on save (`CommandInterpreter#seed_projected_fields`) with `RebuildSweep` retained for out-of-band drift. Full gate green: rspec 2246/2246, model_check 0 errors, doc_coverage clean, rubocop 649 files/0 offenses, parser_parity 38/38, codegen_parity 8/8 (banking's full generated Rust byte-identical to Ruby's). rust_conformance_spec: 14/22 failures, unchanged from before this slice — the Rust runtime doesn't read seeded projected fields at dispatch time yet; that gap is real but separate and out of scope here (Rust runtime projection support, not the DSL/Ruby boundary rule this slice covers). |
| ~~**S13 — coverage standard**~~ (corpus uses / written exemptions for the 11) | everything | **DONE, verified 2026-08-28 — landed 2026-08-15, live-checked now rather than trusted.** `spec/word_coverage_spec.rb` passes clean (3/3): every live `(word, context)` pair from `Hecks::Doc::Reference.live_words` either has a real corpus use in `examples/`, `lib/hecks/language/`, or `lib/hecks/framework/bluebook/`, or a reasoned, named `EXEMPT` entry. The original eleven: `offset`/`nulls`/`inspect_query` gained real corpus uses in `examples/banking/bluebook/{customer_and_compliance_views,payment_cards}.bluebook`; `subscribe` in `banking.hecksagon`; `latest` in `banking.world`; `cursor` and `inspect_query`'s ReadModel form stay exempt (refused unconditionally at build — S15/ADR 0026 removed `cursor` from the core grammar entirely); `tells`/`verb`/`generic` stay exempt with named reasoning (no real integration in this corpus needs the outbound `asks` port direction or a swappable resource port). `formerly_known_as` keeps its external-consumer exemption (embryonautfoundersapp.bluebook). The `domain_port` vs `port` naming note in "Open items" below is stale — `DomainPort` (the `port do...end` aggregate-boundary construct) and `Port` (the standalone resource-port construct persisted_by/opened_by wire into) are two legitimately distinct constructs that happen to share the keyword `port`, not one idea with two names. |

## ADR 0026 slices

Independent of the 0025 waves except where noted.

| slice | note |
|---|---|
| **S14 — `Status` becomes a lifecycle** | **DONE.** `Keyword`/`Argument` became genuine entities of `Syntax` (itself newly dispatched — previously deliberately never-dispatched), each carrying `lifecycle :status, default: "admitted"`. A new `SyntaxBoot` module dispatches the ~284 still-hand-written seed rows into a real "Bluebook" domain runtime once, memoized — real command dispatches through the same admission/coercion/lifecycle-guard door every other command uses. `proposed` deliberately not made reachable (would trigger `bin/model_check`'s own `unreachable_state` ERROR). Full writeup: `project_s14_status_lifecycle_scoping` memory. |
| **S15 — the `Paging` sub-language** | **DONE.** A new `attaches_to` chapter-level word (mirroring `identified_by`'s own append-per-element shape, not a scalar field) lets a chapter name the core contexts its own `Syntax` aggregate contributes rows for — `lib/hecks/language/bluebook/attaches/paging.bluebook` is the one real user so far, declaring `attaches_to "Query", "ReadModel"` and holding the `limit`/`offset`/`cursor`/`nulls` seed rows (deleted from the core's own `syntax.bluebook`). `MetaValidator::ATTACHED_GRAMMAR_DIR` discovers and loads any chapter placed in that directory generically (by the directory's own existence, never by name) ; `SyntaxBoot#all_rows`/`#attached_chapters` merge every attached chapter's rows into the same dispatch sequence the core's own rows populate, so nothing downstream can tell a core row from an attached one. Rust parser gained matching `attaches_to` parsing/emission for parity. Four gates plus `cargo test`/parser parity all green. |
| **S16 — the self-use gate** | **DONE — the whole plan is now complete.** `spec/self_use_spec.rb`, modelled on `spec/fuzzing/meta_domain_coverage_spec.rb`'s claim/gap shape: counts REAL declarations (not grammar rows) of `entity`/`lifecycle`/`policy`/`process_manager`/`ensures`/`provenance`/`group_by`/`authorize` across the core's own chapters. `entity`/`lifecycle` are already real (S17/S14). Adopted `ensures` for real — `Bluebook.Attach` now checks `attaches_to.size == old.attaches_to.size + 1`, the same shape banking's own ensures already uses for an append. The remaining five (`policy`/`process_manager`/`provenance`/`group_by`/`authorize`) are named, reasoned gaps in `SELF_USE_KNOWN_GAPS`: none has a non-decorative site in a domain that only ever describes shape, reacts to nothing, and has no multi-tenant concept — the ADR's own "Rejected alternatives" section names this exact risk for `group_by` by name. Scoped to the CORE only (Bluebook/World/Hecksagon), not every attached sub-language — the ADR leaves that question explicitly open and this spec answers it narrowly rather than deciding it by accident. |
| **S17 — `Member`/`Dispatch`/`Handler` become entities** | **DONE.** The largest single item in either ADR — landed in three checkpoints (a worktree, `worktree-s17-member-dispatch-handler-entities`): entity-list mutations (`:append`/`:remove`/`:multiply`/`:clamp`, EntityInterpreter's own DISPATCH_ORDER gap) ; Member, nested under ValueObject, created by a bare `ValueObject.Member` append (an entity is never created through its own dotted verb — `EntityInterpreter#element_of` only locates) ; Handler/Dispatch, nested two levels deep (`ProcessManager` → `Handler` → `Dispatch`), which needed genuinely new, general runtime capability — EntityBuilder's own nested `entity` word, EntityInterpreter's dispatch/locate/writeback made recursive, and the generic "Entity" meta-category taught to recurse into its own nested entities (via `Entity#owner`, a field the language had declared and never read since ADR 0025's rename — repurposed as the direct parent's id). Also fixed a real, separate, pre-existing Rust parser gap (`sets`'s `multiply:`/`clamp:`/`remove:` declared in the keyword table but never read by `build_mutation`) and added genuine `entity`-inside-`entity` support to the Rust parser to match. All four gates green throughout, plus `cargo test` and parser parity (Rust was touched). |
| **S18 — builder `raise Malformed` → meta-domain migration** | **SCOPED, NOT STARTED.** `lib/hecks/bluebook/meta_validator.rb`'s own header used to claim "delete `language/bluebook/` and validation stops" unconditionally — false as stated: `lib/hecks/bluebook/dsl/` still carries 131 `raise Malformed` call sites across 18 files, none tracked anywhere before this slice. A full read of every site (not a keyword guess) classifies 71 as MIGRATION CANDIDATES — semantic rules over the fully-built IR (a mutation targets a field the aggregate never declares, a query hop crosses a reference it shouldn't, a reference cycle, a `with:` spec naming a field the target doesn't declare — see the per-file table below) — and 60 as STRUCTURAL, checked during Ruby-DSL parsing before a coherent IR exists to dispatch (arity/shape errors, deprecated-word refusals, Ruby-source-extraction failures) and therefore not eligible to become a `given`/`invariant`. Heaviest concentrations: `bluebook_builder.rb` (17 migration / 19 total) and `aggregate_builder.rb` (16 migration / 18 total) — both are almost entirely post-build, cross-construct `seal_*`/`validate_*` batteries already shaped like what a meta-domain `invariant` dispatches against. `translation_builder.rb` is 100% structural (20/20) and is not a migration target at all. Two near-duplicate pairs worth deduping regardless of which bucket: `hecksagon_builder.rb:79`/`binding_proxy.rb:27` ("port needs an aggregate/bluebook to belong to"), and the `seal_cursor` invariant appearing verbatim in both `read_model_builder.rb:217` and `query_builder.rb:106`. Separately, `spec/meta_rule_reachability_spec.rb` (new, this session) found the 62 rules the meta-domain HAS already ported are themselves only 14 proven firing — so this slice's starting point is not "port 71 more rules" but "first close the reachability gap on the 62 already here," per that spec's own `META_RULE_KNOWN_GAPS`. No owner assigned. |

### S18's own inventory, per file

Read directly, not grepped-and-guessed — every `raise Malformed`/`raise DSL::Malformed` in `lib/hecks/bluebook/dsl/` as of this writing, classified MIGRATION (a rule about the shape of the fully-built IR, dispatchable the same way the meta-domain's existing 62 rules are) or STRUCTURAL (has to run during Ruby-DSL parsing, before a coherent IR exists — arity/shape of the DSL call itself, a deprecated-word refusal, a Ruby-source-extraction failure, or builder-only bookkeeping the final IR retains no trace of).

| file | migration | structural | total |
|---|---|---|---|
| `bluebook_builder.rb` | 17 | 2 | 19 |
| `aggregate_builder.rb` | 16 | 2 | 18 |
| `translation_builder.rb` | 0 | 20 | 20 |
| `identity_declaration.rb` | 1 | 12 | 13 |
| `attribute_collector.rb` | 11 | 3 | 14 |
| `command_builder.rb` | 3 | 9 | 12 |
| `read_model_builder.rb` | 8 | 1 | 9 |
| `port_operation_builder.rb` | 5 | 1 | 6 |
| `value_object_builder.rb` | 3 | 3 | 6 |
| `entity_builder.rb` | 2 | 1 | 3 |
| `domain_port_builder.rb` | 2 | 0 | 2 |
| `word_gate.rb` | 0 | 2 | 2 |
| `policy_builder.rb` | 0 | 2 | 2 |
| `generic_dispatch.rb` | 0 | 1 | 1 |
| `hecksagon_builder.rb` | 1 | 0 | 1 |
| `rule_reference.rb` | 0 | 1 | 1 |
| `query_builder.rb` | 1 | 0 | 1 |
| `binding_proxy.rb` | 1 | 0 | 1 |
| **total** | **71** | **60** | **131** |

`translation_builder.rb` being 100% structural is a real, checked finding, not an oversight — it's a flatter DSL (blank-required-kwarg checks only), with no cross-construct shape rules of the kind the other builders carry. A recurring STRUCTURAL pattern worth naming so nobody re-litigates it per-site: several builders check a DSL method was called twice (`role`, `references`, `identified_by`, `version`) — these stay structural because the final IR retains only the last-assigned value, with no trace of the earlier call for a post-build invariant to inspect.

## What cannot be parallelised

- **S3 against S1/S5** — shared `attribute` rows across three contexts.
- **S15 against S4** — both own the Query and ReadModel grammar regions. (DONE — S15 moved `limit`/`offset`/`cursor`/`nulls` OUT of the core's own rows entirely, into Paging's own `Syntax` aggregate, so this conflict is now historical.)
- **S17 against anything** — it restructured the meta-domain that every other slice's validation runs through. (DONE — this constraint is now historical, kept for context.)
- **S14 against S17** — S14 *depended* on S17 landing general nested-entity capability, which it now has. (DONE — both S14 and S17 are landed; this constraint is now historical.)

## A caution about this document

S14 was written here as "self-contained, small, good first slice" and was none of those things: the construct it converts is a value object, and value objects cannot carry a lifecycle. The error survived because the slice was cut from the ADR's *intent* without opening `syntax.bluebook` to see what `Status` was attached to.

Every slice above carries the same risk in proportion to how little of it was verified against the source. The ones stated with file paths and line numbers were checked; the ones stated in prose were reasoned from the ADRs. Before starting any slice, confirm its premise holds in the code — the cost of finding out afterwards is an agent's whole session.
- **Anything against Wave 0** — S0a and S0b change the rules every later slice is written against.

## Open items not yet sliced

Recorded so they are not lost, each small enough to fold into a related slice:

- `Domain::Aggregate.X.Y` is ambiguous between an entity command and a port operation (`dispatcher.rb:67`). Latent — pizzas' `PaymentGateway` is the only port. Fold into S9.
- `parent` is undocumented — a piece reaches its aggregate through it and it appears in no reference page. Fold into S9.
- ADR `0008` says `report` is the business-facing spelling of a read model, which `0025` reversed. Neither records the supersession. Fold into S4.
- The adapter-agreement gate's first stage (`parallel_rspec`) flakes roughly one run in six — one process dies with no reported failure, losing ~132 examples. Unrelated to this work; blocked a push once.
