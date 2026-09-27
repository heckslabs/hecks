---
type: grilling
status: closed
blocked_by: [02-research-silent-wrong-status]
claimed_by:
---

# Silent-wrong bugs: refuse, fix, or both

## Question

The project's thesis is refuse deterministically rather than drift quietly, yet the two
documented defects drift quietly. For each: does it refuse at boot or seal time, get fixed, or
both, and in which order? Where does the refusal live (one place, on the fixed dispatch path),
how does the Rust runtime stay in agreement, and what test would make a future silent-wrong
construct fail the suite? Note `hecks model_check --profile client` already refuses three
constructs; say whether these join that list.

## Prep (not a decision)

Gathered by a read-only agent for the grilling session; the options and recommendation are
input, not the decision.

**Facts**
- Rust drops rows too, so the runtimes agree on the bug. Rust `nest`
  (`rust/src/kernel/read_model.rs:312-340`, `group.into_iter().next()` at `:333`) states the same
  scope limit and returns a bare `Json`, so it has no error path today. Its only caller is the
  generated per-model transform. The fuzz oracle `nest_rows`
  (`lib/hecks/fuzzing/properties/invariants_and_aggregation.rb:326`) copies `stripped.first`,
  so it agrees with the bug by construction.
- A default-on refusal would break nothing in the corpus. `model_check --profile client` over
  the whole corpus reports neither `client_group_by_row_drop` nor `client_dotted_compute_source`.
  Every corpus `group_by` groups by the aggregate's identity or unique-by-construction fields.
  The dotted-source `compute` appears only in specs; the one real corpus `compute` has an
  undotted source. Specs that collide on purpose (`spec/model_check_client_profile_spec.rb:51-61`,
  `spec/runtime/read_model_interpreter_spec.rb`) would need exempting. Downstream domains were
  not searched.
- `ModelCheck.call` runs from `bin/model_check` and `storehouse.rb:716`, not on the default seal
  or boot path, so "default-on" needs a home (wiring into seal, or a check in
  `read_model_builder.rb:355-365`).
- Fix sizes. Dotted compute is small: one method, `compile_compute`
  (`rule_compiler.rb:131-140`), about 10-20 lines using the existing path helper
  `hecks_tr_extract`, plus flipping the pending example and deleting the client rule and
  README caveat. The Rust host appears to consume Ruby-compiled SQL, so no separate Rust change
  is expected (not traced through `mint.rs`). `group_by` is medium: ADR 0061's Option 1 touches
  Ruby `nest`, Rust `nest` with `Result` plumbing through two generators, a shared refusal
  wording, the fuzz oracle and three docs, about 6-8 files, and is data-dependent.
- ADR 0061 is still "Proposed" (`:3`). Its Decision adopts Option 1 now, refusing a colliding
  leaf at dispatch on both runtimes (`:129-146`); D1 (`:341-343`) is open for a human. A
  build-time check is impossible except when the key covers the aggregate's identity
  (`groups_by_identity?`, `client_profile.rb:135-141`). Nothing in any ADR covers dotted
  `compute`.

**Options**
1. Promote the two client rules to a default seal-time refusal. Small, Ruby only, no Rust
   plumbing; refuses safe non-identity keys too (stricter than the ADR) and does not help models
   already loaded.
2. ADR 0061 Option 1 as written: runtime refusal on collision plus the identity shortcut at
   seal, both runtimes, one shared sentence. Never wrong, but data-dependent and the largest
   cost, and it fixes only `group_by`.
3. Fix the dotted-compute SQL only. Removes the defect class with a small diff and an existing
   test; leaves `group_by`.
4. Keep the opt-in profile and correct the docs. Trivial; the thesis stays violated by default.

**Recommendation from prep, in order.** (1) Option 3 now. (2) Adopt ADR 0061 D1 as option 2.
(3) Until that lands, promote only the `group_by` identity rule to a default seal-time check,
which nothing in the corpus trips. (4) Fix the `README.md:610-615` wording ("on the in-memory
adapter") now. (5) Keep the retire-with-the-bug probes: they are the test that makes a future
silent-wrong construct fail the suite.

**For the maintainer**
- Is a data-dependent runtime refusal acceptable, or should seal refuse every non-identity key,
  false positives included?
- Should the default-on gate run at seal or boot, or only in `model_check`?
- For dotted compute, should the source reach the author's SQL as a flattened column alias or
  keep being read through `__s`?
- Do any downstream domains use a colliding `group_by` or a dotted compute? Not checked.
- Is ADR 0061 accepted or still a draft?

## Answer

Decided 2026-09-27: accept the prep plan. Fix the dotted-source `compute` SQL now; adopt ADR
0061 decision D1 (a runtime refusal on a colliding `group_by` on both runtimes, plus the
identity shortcut at seal); until that lands, refuse a non-identity `group_by` key at seal by
default; correct the README wording now. Order: README wording and the compute fix, then the
seal-time stopgap, then the runtime refusal. Recorded in
[ADR 0065](../../../decisions/0065-silent-wrong-constructs-are-refused-or-fixed.md).
