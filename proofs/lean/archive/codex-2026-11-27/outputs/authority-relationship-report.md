# Relationship authority boundary follow-up

## Result

An explicit World/actor wrapper now has a mechanical **arbitrary-length noninterference theorem**: when actor and World differ, executing any finite list of the protected instructions cannot change durable state or committed events. The program's composed relation exactly matches the protected interpreter. Lean also checks a concrete cross-World write refusal and proves that a bypassing adapter has a different outcome.

The ancestral Hecks `environment_caller_role.json` fixture independently exhibits the relevant pattern: two wrong-role `Account.Open` attempts leave the same record set and event sequence; a subsequent `Branch clerk` attempt adds one account and one event. This is behavior evidence, **not** a refinement proof from Hecks role grants to the model's actor-equals-World rule.

## Exact Lean check

[AuthorityRelationship.lean](AuthorityRelationship.lean) imports the checked [executable fragment](ExecutableRelationship.lean). Command: `LEAN_PATH=work work/lean-4.36.0-darwin/bin/lean outputs/AuthorityRelationship.lean`. Exit status `0`; standard error empty. Exact standard output in [authority-lean-check.txt](authority-lean-check.txt):

```text
'AuthorityRelationship.protected_run_realizes_relation' depends on axioms: [propext]
'AuthorityRelationship.unauthorized_program_cannot_commit' depends on axioms: [propext, Classical.choice, Quot.sound]
'AuthorityRelationship.cross_world_write_is_refused' does not depend on any axioms
'AuthorityRelationship.bypass_is_not_protected' does not depend on any axioms
```

There is no `sorry`, `admit`, or custom axiom. The listed axioms are standard Lean axioms. The theorem includes preservation of the World and actor identifiers, and applies to every list of the finite instruction type. Its proof assumes the `protectedStep` wrapper is the only execution path. `bypass_is_not_protected` demonstrates why that premise matters.

## Hecks probe

[authority_corpus_probe.rb](authority_corpus_probe.rb) replays each prefix of the frozen fixture in a fresh temporary Memory domain through `Hecks::Fuzzing::Replay`. It compares the observable instance keys and ordered event names after each prefix. Exact output is in [authority-corpus-results.json](authority-corpus-results.json); exit status `0`, standard error empty. The decisive observations are:

| Prefix | Refusals | Instance keys | Events |
|---|---|---|---|
| Customer registered | none | Customer | CustomerRegistered |
| First wrong role | Unauthorized | unchanged | unchanged |
| Second wrong role | Unauthorized, Unauthorized | unchanged | unchanged |
| Allowed role | same two prior refusals | Customer and Account | CustomerRegistered, AccountOpened |

This tests Hecks's role mismatch path at one command and one fixture. Hecks also has tenant boundary and cross-tenant reference checks, distinct from this role fixture. The Lean model uses equality of numeric actor and World IDs as a deliberately narrow stand-in; it does not model Hecks's grants, ambient caller binding, tenants, delegation, or independently governed Worlds. It therefore does **not** establish general Hecks authorization parity.

## Implication for the one-construct question

Authorization can be written as a condition relation and composed with a transition relation. That supplies a specification. The proof requires an enforcement boundary: every entry point must pass through the condition, and adapters must not bypass it. This is another case where one denotational Relationship type does not eliminate a consequential operational distinction. The next step is to make the executable instruction grammar typed by World and capability, then prove a real adapter/refinement boundary rather than a wrapper theorem alone.

No ancestral source was changed. No push, tag, release, or publication occurred.
