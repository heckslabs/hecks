# A construct that silently returns a wrong answer is fixed or refused, and the two known ones are sequenced

**Status:** Accepted — implemented in 2.8.0, except decision 3. Decisions 1, 2 and 4 shipped: the dotted-`compute` fix, the `group_by` refusal on both runtimes, and the README correction. Decision 3, the interim seal-time check, was not built, because decision 2 landed first and made it moot. [ADR 0061](0061-query-dsl-aggregation-count-sum-group-by.md) remains the design record for the `group_by` refusal (decision 2).

## Context

The project's position is to refuse deterministically rather than drift quietly: a declaration the runtime cannot honor stops at seal or dispatch time with a stated reason, and never returns a plausible wrong answer. Two documented defects contradict that position, and both still reproduce on the current tree.

**`group_by` drops rows that share a key path.** `nest` keeps the first row per full key (`lib/hecks/runtime/read_model_interpreter.rb:279-290`, the `stripped.first` at line 288). It runs on whichever adapter supplied the rows, because a `group_by` read model never takes the native query path. The README says this happens "on the in-memory adapter" (`README.md:610-615`); that is wrong. It happens on every adapter and in Rust, whose `nest` (`rust/src/kernel/read_model.rs:312-340`, `group.into_iter().next()` at line 333) states the same scope limit and returns a bare `Json`, so it has no error path today. Seal time (`lib/hecks/bluebook/dsl/read_model_builder.rb:355-365`) checks only the shape and that the field exists. The fuzz oracle `nest_rows` (`lib/hecks/fuzzing/properties/invariants_and_aggregation.rb:326`) copies `stripped.first`, so it agrees with the bug by construction.

**A `compute` whose source is dotted never fires on PostgresEra.** `compile_compute` (`lib/hecks/ports/persistence/plugins/era/translation/rule_compiler.rb:131-140`) tests `__s ? 'price.cents'`, which asks for a top-level key literally named `price.cents`, so the `ELSE __s` branch returns the state unchanged. The mint succeeds and the record keeps its old value. Dotted destinations work, because only the destination goes through `path_literal`. The repo's own pending example (`spec/adapters/driven/postgres_era/migration_data_safety_spec.rb:443`) demonstrates it, and the path-aware helper `hecks_tr_extract` already exists in the same file. No ADR covers this defect.

The only refusal today is the opt-in `hecks model_check --profile client`: `client_group_by_row_drop` and `client_dotted_compute_source` in `lib/hecks/bluebook/model_check/client_profile.rb`, each with a retire-with-the-bug probe in `spec/model_check_client_profile_spec.rb`. `model_check` does not run on the default seal or boot path. Run over the whole corpus, the profile reports neither rule: every corpus `group_by` groups by the aggregate's identity or by fields that are unique by construction, and the dotted-source `compute` appears only in specs.

## Decision

1. **Fix the dotted-source `compute` SQL now.** Rewrite `compile_compute` (about 10-20 lines) to read the source through `hecks_tr_extract`, as the destination already is. Flip the pending example at `migration_data_safety_spec.rb:443` to a passing one, delete the `client_dotted_compute_source` rule and its probe, and correct the caveat at `README.md:623-626`. The Rust host appears to consume Ruby-compiled SQL, so no separate Rust change is expected; that has not been traced through `mint.rs`.
2. **Adopt ADR 0061 decision D1 as written.** A colliding `group_by` leaf is refused at dispatch on both the Ruby and the Rust runtime, with one shared refusal wording, plus the identity shortcut at seal time: a key path that covers the aggregate's whole identity is accepted without a runtime check. The fuzz oracle `nest_rows` stops mirroring `stripped.first` and asserts the refusal instead.
3. **Until decision 2 lands, refuse at seal time a `group_by` whose key does not cover the aggregate's whole identity,** by default and not only under `--profile client`. Nothing in the corpus trips it. It retires when decision 2 lands.
4. **Correct the README wording at `README.md:610-615`** to say the row drop happens on every adapter and in Rust.

The probes in `spec/model_check_client_profile_spec.rb` stay until each bug is fixed. They are the test that makes the next silent-wrong construct fail the suite, and each retires with its bug.

Order: decisions 4 and 1 first, then 3, then 2.

## Consequences

- A PostgresEra `translations:` rule with a dotted `compute` source starts doing what it says. A mint whose old, unfired result had been relied on will now change the migrated record.
- Under decision 3, a model that groups by a non-identity key (for example `group_by :kind` alone) is refused when it is sealed, even if its data never collides. Every corpus model and every known spec passes except the specs that collide on purpose (`spec/model_check_client_profile_spec.rb:51-61`, `spec/runtime/read_model_interpreter_spec.rb`), which need exempting. Decision 3 is deliberately stricter than ADR 0061 and goes away with it.
- Under decision 2, the refusal is data-dependent: a read model that answered yesterday can refuse today when a second row reaches the same key path. That is accepted, because a refusal at the first collision beats a silently truncated answer. Rust `nest` gains an error path, which touches both Rust generators, the shared refusal wording, the fuzz oracle and the docs, roughly six to eight files.
- Once decision 2 ships, a model that groups by a non-identity key is accepted at seal time and refused per request, when the data collides. The two checks are not equivalent, so the seal-time check is removed and not left beside it.
- Reading the docs stops misleading: the `group_by` limit is stated correctly, and the dotted `compute` caveat is deleted.

## Alternatives considered

- **Refuse both at seal, Ruby only** (promote the two client rules to a default). Small, and needs no Rust plumbing. It refuses safe non-identity keys as well, which is a false positive for any model whose key is unique in practice, it does not help models already loaded, and it leaves Rust returning the wrong answer. Kept only in the narrow form of decision 3, as a stopgap.
- **Fix the dotted `compute` only.** Removes one defect with a small diff and an existing test, and leaves `group_by` drifting quietly. This is decision 1 without the rest.
- **Keep the opt-in profile and correct the docs.** Trivial. The thesis stays violated by default for anyone who does not run the client profile.

## Open items

- ADR 0061's status moves from Proposed to Accepted when decision 2 ships; until then it is the design record and this ADR is the sequencing.
- Downstream domains have not been searched for a colliding `group_by` or a dotted `compute`. Decision 3 could refuse one of them at seal time, and decision 1 could change one of their migrated records.
- Where the default seal-time check in decision 3 lives (a check in `read_model_builder.rb` or a wiring of `ModelCheck` into the seal path) is left to whoever builds it.
