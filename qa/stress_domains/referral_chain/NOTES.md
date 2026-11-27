# `ReferralChain` — retention note

**Kept.** Built for ANGLE-2 in the QA ledger (`qa/bluebook`): reference
HOPS, as distinct from the entity NESTING `qa/stress_domains/
nested_pieces` already covers. The premise, quoted from the angle
itself: "a chain of reference-typed lookups across aggregates ... ADR
0037's own Finding 5 already shows reference resolution is exactly the
kind of place Ruby and Rust structurally diverge." The domain is three
aggregates in a `reference_to` chain — `Referral -> Member -> Sponsor`
— and nothing else, one construct per gap it exists to exercise (the
header comment on `bluebook/referral_chain.bluebook` walks each one).

## What was checked before authoring this

- No aggregate anywhere in the corpus declares `has_many` (`grep -rn
  has_many examples/ qa/ spec/fixtures/` — only `spec/dsl_spec.rb`'s own
  unit example does); `belongs_to` appears once (`SafeDepositBox`).
- A ONE-hop `where` exists (`Banking::Account.OpenForSuspendedCustomers`,
  `customer/status`) and is a structural skip in Rust already — so a
  one-hop query would add nothing, and this domain declares none. A
  TWO-hop `where` exists only in `spec/fixtures/hop_chain.bluebook`,
  never in a fuzzed domain.
- A TWO-hop `given` through a fresh argument exists once
  (`Banking::Transfer.Request`, `source.customer.status`); banking is
  the only target carrying it.
- ADR 0037 Finding 5's own trigger — a command redeclaring the
  aggregate's reference field under a plain value-object type — was
  removed from the corpus by #409 and never reintroduced; the ADR's
  closing note says to re-open the finding "the day one does."
- `bin/qa_domain_novelty qa/stress_domains/referral_chain` (this PR's
  own gate, measured against every `Target.path` in the ledger) reports
  seven form pairs no existing target meets on one aggregate, all on
  `Referral`: `has_query + multi_hop_where`, `has_query +
  revalued_reference`, `multi_hop_where + reference_attr`,
  `multi_hop_where + revalued_reference`, `multi_hop_where +
  two_hop_given`, `reference_attr + revalued_reference`,
  `revalued_reference + two_hop_given`. The three reference-hop forms
  themselves (`two_hop_given`, `multi_hop_where`, `revalued_reference`)
  joined `Hecks::Fuzzing::FormCensus` with this domain — the thirteen
  original forms are already met pairwise by banking alone, so a
  domain has to name the form it is for before the gate has anything to
  find (the script's own header says why that is the honest shape).

## What this domain found, first real run

Four distinct findings — one at codegen time, three from the
differential fuzz (`spec/rust_conformance_fuzz_spec.rb`'s exact
comparison, run out of band over this domain at `SEEDS=10` then
`SEEDS=40`, 25 steps, adversarial fraction 0). None fixed here, on
purpose — same restraint `waybill`/`nested_pieces` held to: the
`Bug.log`/judgment/fix lifecycle belongs to the session holding the
ledger.

### 1. `has_many` has no compilable Rust projection (codegen)

The first draft carried a fourth aggregate, `Circle` (`has_many Members`,
plus `Admit` supplying the list under `list_of(Handle)`), to reach
`resolve_state_references`' LIST branch (`lib/hecks/runtime/
command_rules/references.rb:42-53`). `bin/project_rust` accepted it and
emitted `rust/src/generated/referral_chain/circle.rs` that does not
compile — three errors, two root causes:

```
error[E0599]: no method named `to_json` found for reference `&String`
   --> circle.rs:196   ("members".to_string(), Json::Array(self.members.iter().map(|x| x.to_json()).collect()))
error[E0433]: failed to resolve: use of undeclared type `ReferenceMember`
   --> circle.rs:208   items.iter().map(ReferenceMember::from_json)
error[E0609]: no field `value` on type `Vec<circle::Handle>`
   --> circle.rs:414   record.members = args.members.value.clone();
```

The first two are the aggregate's own `list_of(Reference<Member>)`
storage field: codegen types it `Vec<String>` (correct — a reference is
a bare id) but serialises and deserialises its elements as if they were
a value object named `ReferenceMember` (`rust/project/json_codec.rb`'s
list emitters never special-case a reference element type the way
`naming.rb#reference_type?` does for scalars). The third is the
`sets :members` mutation collapsing a `Vec<Handle>` argument onto the
reference list with the SCALAR value-object collapse (`.value`). The
first two fire with or without `Admit` — a `has_many` field alone is
enough. And because `rust/src/generated/mod.rs` declares every
generated domain with an unconditional `pub mod`, the broken file
failed EVERY feature's build (`cargo build --no-default-features
--features waybill` reproduced all three errors), not just this one's
— so the projection could not be committed at all. `Circle` was
removed; the committed domain carries the Finding 5 shape on a scalar
reference instead (below), and `has_many` comes back the day codegen
can project it. Demonstration: add `has_many Members` to any aggregate
in any generated domain, `bin/project_rust` it, `cargo build`.

### 2. ADR 0037 Finding 5, re-opened exactly as predicted (runtime)

`Referral.Reassign` redeclares `member` under `Handle` and `sets
:member`. Ruby refuses a handle naming no Member with `NotFound` — from
`resolve_state_references` at `step_save`
(`command_interpreter.rb:287`), the check that walks `Referral.member`'s
real `Reference<Member>` type against the SETTLED state, since the
command's own attribute is not `reference?` and the command-level
`resolve_references` (the one Rust ported, `rust/project/domain_
generator.rb#reference_checks`) has nothing to check. Rust accepts the
dispatch, emits `ReferralReassigned` with a value-object-shaped payload
(`"member": {"value": "hotel"}`) and stores `"member": "hotel"` — a
dangling reference, the same silent data-integrity violation the ADR
originally catalogued on `SafeDepositBox.Rent`.

- **Signature**: Ruby refusals carry `ReferralChain::Referral.Reassign
  NotFound`; Rust's carry nothing for that step; `instances` and
  `events` then diverge (Rust holds a `member` naming no record, and a
  `ReferralReassigned` Ruby never emitted).
- **Frequency**: 19 of 40 seeds carry this signature and nothing else;
  52 such Ruby refusals across the 40-seed run; every one of the 66
  field divergences at `SEEDS=40` involves it or one of the two
  signatures below.
- **Repro**: seed 2, step 9 — `ReferralChain::Referral.Reassign
  {"member":{"value":"india charlie juliet"},"code":{"value":"juliet
  delta"}}` (also steps 16 and 21 of the same seed; seed 6 step with
  `{"value":"hotel"}`; seed 8, `{"value":"echo foxtrot india"}` then
  `{"value":"x"}`). `spec/referral_chain_spec.rb`'s "refuses to re-point
  a referral at a handle naming no member" example is the one-line
  Ruby-side demonstration.

This is the port the ADR's own "what a future session should do" list
already called for (walk the AGGREGATE's own reference attributes
against settled state, in the generated dispatch's pre-save step, in
both generators) — `resolve_state_references`' scalar branch is enough
to close this instance; its list branch is moot until finding 1 is.

### 3. A bare non-string scalar for a reference argument (runtime)

Independent of `Reassign` — it fires on `Member.Join`'s and
`Referral.Issue`'s ordinary `reference_to` arguments, which every
reference-carrying command in the corpus shares. When the generator
offers a reference as a bare Boolean, Array or `null`:

| step | offered | Ruby | Rust |
|---|---|---|---|
| seed 23, step 15 | `Referral.Issue {"member": false, ...}` | `NotFound` — `no Member with handle "false"` | `TypeMismatch` — `IssueArgs.member: expected String` |
| seed 33, step 2 | `Member.Join {"sponsor": true, ...}` | `NotFound` — `no Sponsor with handle "true"` | `TypeMismatch` — `JoinArgs.sponsor: expected String` |
| seed 21, step 23 | `Member.Join {"sponsor": [8, 8], ...}` | `NotFound` — `no Sponsor with handle "[8, 8]"` | `TypeMismatch` — `expects String, got [8,8]` |
| seed 25, step 11 | `Member.Join {"sponsor": null, ...}` | `GivenNotMet` — the sponsor is in good standing | `TypeMismatch` — `expects String, got nil` |
| seed 2, step 15 | `Referral.Issue {"member": null, ...}` | `GivenNotMet` — the member's sponsor is in good standing | `TypeMismatch` — `expects String, got nil` |

Ruby refuses only an OBJECT-shaped reference by shape
(`refuse_object_reference` — seed 33 step 5's `{"cents":282}` is
`TypeMismatch` on both engines, agreed); every other non-string is
`.to_s`'d by `reference_key` (`references.rb:124-129`) and looked up,
and a `nil` reference is skipped outright (`next if held.nil?`,
`references.rb:30`) so the dispatch runs on to the `given`, which
dereferences nothing and fails. Rust's generated `from_json` requires
a JSON string for every reference field before anything else runs.
Kinds differ, so the by-kind comparison (C8.2) sees it. Whether Ruby's
tolerance is the contract (ADR 0037 Finding 1 calls Integer/Bool
standing in for a String "deliberately tolerated" for value-object
fields) or Rust's strictness is, is the judgment the ledger owes this
one — but for a REQUIRED reference offered as `null`, Ruby answering
`GivenNotMet` rather than anything about the reference at all is hard
to read as intended.

### 4. `GivenNotMet` vs `AlreadyExists` on a creating command (runtime)

Seed 21, step 4: `Member.Join {"sponsor":"india","handle":{"value":
"juliet"}}` where sponsor `india` exists but is `suspended` AND a Member
`juliet` already exists. Ruby: `GivenNotMet` (`enforce_givens` is step
7 of `AggregateDispatchOrder`, `lib/hecks/vocabulary.rb`; the duplicate
is only ever refused at `save`, step 15, by the adapter's own atomic
insert — `raise_for_persistence_outcome!`, `command_interpreter.rb:
317-322`). Rust: `AlreadyExists` — the kernel's own creation check
(`rust/src/kernel/dispatch.rs:253`) refuses the duplicate identity
before the generated dispatch function, and the `given` inside it,
ever runs. Not
reference-specific at all (any creating command with a `given` whose
identity collides can reach it — `Banking::Account.Open` has the same
two ingredients), just never generated in the same step before. The
adversary's `nonexistent+mismatch`-style precedence shapes (PR-2) are
exactly the tool that would pin this deliberately rather than by luck.

## Ruby-only fuzz status

`bin/fuzz qa/stress_domains/referral_chain --seeds 40 --steps 30` —
CLEAN, 40 of 40 seeds, no property violation, no interpreter
exception. `bin/model_check qa/stress_domains/referral_chain` — 0
errors, 1 warning (`Sponsor`'s terminal `suspended`, expected).
`FromGoodSponsors` (the two-hop `where`) is a structural skip on the
Rust side (`"is not generated for this domain"` — `rust/project/
queries.rb`, same boundary as banking's one-hop query), so it is
compared on Ruby's side only, by `query_answers_match_reference`;
PR-2's structural-skip reporting is what will make that skip visible
per sweep.

## Not fixed here, on purpose

Same restraint `waybill` and `nested_pieces` exercised: this domain was
authored from an isolated worktree, and the `Bug.log`/`triage`/fix
lifecycle belongs to the session holding the ledger. Findings 2, 3 and
4 each have a seed and step above; finding 1 has a one-line
demonstration. None is a defect in this domain's own bluebook — the
domain was authored correctly from the start, and `spec/referral_chain_
spec.rb` pins the Ruby answers Rust is being compared against.
