# `CaseEscalation` — retention note

**Kept.** Realizes ANGLE-12 (`ask backlog`, QualityControl ledger): two
feature-coverage gaps (`spec/fuzzing/meta_domain_coverage_spec.rb`
`META_DOMAIN_KNOWN_GAPS`) meet on nothing in the corpus today —
`Policy#target_domain` (no fuzzer property ever asks whether an `across`
policy's declared target actually resolves, because every real `across`
policy in the corpus targets a Lambda-deployed sibling domain never loaded
into the same registry under fuzzing) and `Command#references` (nothing
asks whether a `corrects` command re-validates a reference that has gone
dangling since the event being corrected was recorded). `ReadModel#
aggregate_heads` (multi-head `include` composition beyond the one
`aggregation_matches_recompute` already checks) rides along, exercised here
for the first time over a chapter reached only by a cross-domain policy.

**`bin/qa_domain_novelty` reports "no new pair" — read that as a gap in the
census, not in this domain, the same way `qa/stress_domains/corrections`'
own NOTES.md and `qa/stress_domains/tenant_ledger`'s own did.**
`Hecks::Fuzzing::FormCensus::FORMS` has no entry for `corrects`, for an
`across` policy's `target_domain`, or for a read model's own aggregate-head
count — none of the three constructs this domain exists to pair are
tracked dimensions of that census at all, so it necessarily measures
"nothing new" regardless of what this domain actually proves. The honest
gate for `corrects` and `target_domain`-resolution is `Hecks::Fuzzing::
Properties::FEATURE_COVERAGE` (`lib/hecks/fuzzing/properties.rb`) and
`spec/fuzzing/meta_domain_coverage_spec.rb`'s own `META_DOMAIN_KNOWN_GAPS`
— both cited above, both real, both still open after this domain (a
stress domain proves the SHAPE dispatches; it does not itself add the
missing PROPERTY that would check it on every future domain, the same
distinction corrections' own NOTES.md draws for its own `corrects`
finding). Adding `has_corrects`/`cross_domain_policy` as tracked
`FormCensus` forms — the same move `referral_chain` made for the
reference-hop family — is a reasonable follow-up, not attempted here to
keep this domain's own change scoped to authoring and proving the domain.

## 1. The in-process cross-domain policy resolves and dispatches for real — confirmed live, the first time any `across` policy in this codebase has

Every `across` policy that exists anywhere else in the corpus
(`examples/banking`, four of them — `ReviewOnFreeze`/`ReviewOnBoxSurrender`
→ `"Compliance"`, `NotifyOnClosure`/`FlagKeyReturn` → `"Notifications"`)
targets a domain deployed to its own separate AWS Lambda
(`banking.hecksagon`'s own comment: "real cross-domain delivery, `rust/
host`'s own `lambda_client.rs`") and is never loaded into the same
registry Banking itself boots into for fuzzing (`bin/fuzz`, `bin/qa_sweep`,
`spec/rust_conformance_fuzz_spec.rb`) — so under every fuzz run that
exists today, all four of those dispatches hit a `DOMAIN_REFUSAL` (the
target chapter simply isn't there), get recorded `delivered: false` by
`PolicyInterpreter#deliver`'s own rescue, and are never genuinely
exercised end to end.

This domain's second chapter (`review.bluebook`, `"VendorCompliance"`)
sits in the SAME `bluebook/` directory as `case_escalation.bluebook`
(`"CaseEscalation"`), and `Adapters::Folder#load_domain`
(`lib/hecks/adapters/driven/folder.rb:127`) — the same glob `Hecks::
Fuzzing::FormCensus.census` and `bin/qa_domain_novelty` both use — loads
every `*.bluebook` file there into ONE registry. Confirmed by direct
dispatch, not merely declared:

```
Vendor.Enroll(handle: "acme")     → VendorEnrolled
Vendor.Enroll(handle: "beta")     → VendorEnrolled
Invoice.RecordCharge(reference: "inv-1", vendor: "acme", amount: 100) → ChargeRecorded
Invoice.AmendCharge(invoice: "inv-1", vendor: "beta")                 → ChargeAmended
  reactions: [{policy: "FlagAmendment", on: "ChargeAmended",
               trigger: "VendorCompliance::Review.Open", delivered: true}]
VendorCompliance::Review.All → [{vendor: "beta", invoice: "inv-1", status: "open", id: "beta"}]
```

**A real domain-authoring lesson, not a runtime bug**, found on the first
attempt: `trigger_args` (`lib/hecks/runtime/policy_interpreter.rb:252`)
forwards a triggering event's ENTIRE payload, unfiltered, when a policy
declares no `with_spec` — and `ChargeAmended`'s own payload turned out to
carry both `vendor` (what `AmendCharge` `sets`) AND `invoice`
(`AmendCharge`'s own `reference_to Invoice`, resolved and folded into the
emitted event's args even though nothing `sets` it explicitly — an
aggregate-level command's addressing reference lands in its own event's
payload, unlike an entity command's, per `corrections/NOTES.md`'s own
comment on that asymmetry). The first draft of `Review.Open` declared
`vendor` alone; every dispatch of `FlagAmendment` failed to deliver,
`reactions:` recording `"Open does not declare invoice — it takes
vendor"`, silently non-fatal to `AmendCharge` itself (a policy failing to
deliver is a `DOMAIN_REFUSAL`, never raised to the command that emitted
the triggering event) — worth knowing for anyone else's first `across`
policy with no `with_spec`: the triggered command has to accept the WHOLE
payload shape, not just the field it cares about.

## 2. The revalued-reference `corrects` command refuses a dangling vendor correctly — a real negative result, not (yet) a bug

`AmendCharge`'s own `vendor` argument is redeclared under this
aggregate's own `Handle` value object rather than `Reference<Vendor>` —
the exact ADR 0037 Finding 5 / `referral_chain`'s own `Referral.Reassign`
shape, now on a `corrects` command. Confirmed live: `AmendCharge(invoice:
"inv-1", vendor: "ghost-vendor-does-not-exist")` raises
`Hecks::Runtime::NotFound` ("no Vendor with handle
\"ghost-vendor-does-not-exist\""), the same as an ordinary command would
— meaning `resolve_state_references` (the settled-state check, never
ported to Rust) DOES run on this aggregate-level `corrects` command's own
mutation path. This is the aggregate-level counterpart to `qa/
stress_domains/corrections`' own BUG#30 (an ENTITY-level `corrects`
crashes outright, `no entity mutation applier handles :corrects`) coming
back clean rather than broken — a genuine, useful negative result:
whatever gap entity-level `corrects` has in `EntityElement#apply_to_
element`'s own `case mutation.op` does not appear to have an
aggregate-level twin in `MutationApplier#apply`, which corrections' own
NOTES.md already names as treating `:corrects` as a documented no-op.

**Not yet checked, and the reason this domain is registered as a live
`Target` rather than closed here**: whether Ruby and a compiled Rust
binary AGREE on this refusal's ORDERING against the OTHER admissibility
checks a `corrects` command also carries (does `NothingToCorrect` — the
check that `ChargeRecorded` was actually emitted for this Invoice — run
before or after `resolve_state_references`, and does that order match
Rust's own, given `corrections`' own BUG#31 already found Rust's generated
`emit_entity_command` skips the admissibility check `corrects` needs
entirely at the entity level); whether `bin/qa_sweep`'s self-consistency
axis (cold rehydration, replay idempotency) agrees with itself across a
`FlagAmendment` reaction that crosses chapters; and whether
persistence-parity (Memory vs. real Postgres) holds for a read model
composed over an `across`-reached chapter. That is `bin/qa_sweep`'s own
job, not this note's.
