---
title: "Compile-Time DDD Validation with Remediation-Bearing Errors"
authors: "Chris Young"
version: "paper/prior_use-v1-2026-04-24"
commit: "c4a903f3"
date: 2026-04-24
---

# Compile-Time DDD Validation with Remediation-Bearing Errors

**Version:** `paper/prior_use-v1-2026-04-24`
**Repository commit at time of writing:** `c4a903f3`
**Author:** Chris Young

## Abstract

Domain-Driven Design (DDD) practices — naming aggregates, choosing verbs for
commands, wiring references, composing policies — are typically enforced in
code review, where the enforcement is inconsistent and the feedback arrives
late. We report a framework, Hecks, in which DDD conformance is checked at
*parse time* over a declared intermediate representation (IR), the checks are
expressed as shape-only data rather than as hand-written Rust, and every
violation carries a concrete remediation hint targeted at the developer's
next edit. Twelve rules across three validator groups (core structural,
lifecycle, warning-class) cover aggregate naming, command naming, reference
resolution, policy targeting, alias disambiguation, lifecycle coverage,
duplicate-policy detection, and complexity warnings. Each rule's identity,
description, inspection target, check kind, error template, and optional
embedded Rust body fragment is declared as a `.fixtures` row; the running
validator is generated from those rows. A golden test at the module level
asserts that the generated file is byte-identical to a prior known-good
artifact, so the validator is both data-driven and regression-protected. We
place the technique in the public record as prior art.

---

## §1 Introduction

DDD practitioners accumulate a small library of rules they apply by eye:
aggregates shouldn't share names across a bounded context; commands should
start with verbs; a `reference_to` should resolve to a declared aggregate;
two references to the same target need distinct aliases, otherwise
downstream event payloads can't tell them apart; policies shouldn't fire the
same trigger twice. These rules are cheap to check mechanically and
expensive to miss in code review.

The standard places to enforce them are (a) code review, which is not
mechanical, (b) a linter layered on top of the production code, which
requires the production code to have landed in order to be checked, and (c)
runtime assertions inside the framework, which shift the error from *edit
time* to *boot time* — past the window where a fix is cheap.

We describe a fourth option. Validate at *parse time*, over a declared IR,
before any generator consumes the domain. Express the rules as shape-only
data so the validator can be regenerated rather than edited. Attach a
concrete remediation hint to each violation so the message a developer reads
tells them what to type next.

### §1.1 Contribution

The contributions are:

1. Twelve DDD rules, each expressed as a shape-only `.fixtures` row with a
   declared inspection target, check kind, error template, and — for
   structural checks that can't be expressed templately — an embedded Rust
   body fragment. Located at `hecks_conception/capabilities/validator_shape/`,
   `.../lifecycle_validator_shape/`, `.../validator_warnings_shape/`, and
   `.../duplicate_policy_validator_shape/`.
2. A build-time validator generated from those rows
   (`hecks_life/src/validator.rs`, etc.) with a GENERATED FILE header
   citing its regenerator.
3. A remediation-first error format:
   `{parent} has {count} references to {target} with duplicate alias {name:?} — add \`as: :<alias>\` to each so they have distinct names`.
   Every error template carries the fix.
4. A byte-identical golden test
   (`hecks_life/tests/specializer_golden_test.rs`) asserting the generated
   validator does not drift from the approved artifact.
5. A CLI surface: `hecks verify` runs the full validator suite in under
   0.3 s against the in-repository chapter bluebooks, returning a
   zero/nonzero exit suitable for pre-commit wiring.

### §1.2 Paper organisation

§2 states the problem and the design goal. §3 enumerates the twelve rules.
§4 describes the remediation-first error format. §5 describes the
shape-as-data declaration and generator path. §6 shows a worked example. §7
compares to adjacent work. §8 lists novel claims. §9 closes.

---

## §2 The Problem

Consider a developer writing a Bluebook. They declare an aggregate:

```ruby
aggregate "Account" do
  reference_to Customer
  reference_to Customer
  command "Debit" do
    attribute :amount, Integer
  end
end
```

The aggregate has two references to `Customer` without distinguishing
aliases. Downstream, when the framework generates event payloads, form
fields, or Ruby routing, the two references are indistinguishable — a bug
that surfaces not at the point of declaration but the first time a generator
emits ambiguous code. By that point the developer has moved on; they are
debugging a failed generation, not their design.

The same shape applies to: commands named with non-verbs (`Account` on
`Account` rather than `OpenAccount`); `reference_to Customr` with a typo;
policies triggering a command that no longer exists; two policies
subscribing-and-triggering the same pair, producing a cascade that emits the
same event twice.

The framework knows enough at parse time to catch each of these. What's
needed is (i) a place to put the rules, (ii) a discipline to keep them
declarative rather than ad-hoc, and (iii) an error format that points at the
fix instead of at the problem.

---

## §3 The Twelve Rules

The rules partition into four validator groups by concern. Each rule has a
canonical fixture name, a Rust function name (used by the generator), an
inspection target, a check kind, and an error or warning template.

### §3.1 Core structural rules (`validator_shape`)

Seven rules, all errors (blocking):

| Rule name                     | Inspects                                                      | Check kind        | Error template (abridged)                                                                        |
|-------------------------------|---------------------------------------------------------------|-------------------|--------------------------------------------------------------------------------------------------|
| `unique_aggregate_names`      | `domain.aggregates`                                           | `unique`          | `Duplicate aggregate name: {name}`                                                               |
| `aggregates_have_commands`    | `domain.aggregates`                                           | `non_empty`       | `{name} has no commands`                                                                         |
| `command_naming`              | `domain.aggregates[].commands`                                | `first_word_verb` | `Command {name} in {parent} starts with '{word}' which looks like a {pos} — commands should start with a verb` |
| `valid_references`            | `domain.aggregates[].references` + commands[].references      | `reference_valid` | `{parent} references unknown aggregate: {target}`                                                |
| `valid_policy_triggers`       | `domain.policies`                                             | `trigger_valid`   | `Policy {name} triggers unknown command: {trigger}`                                              |
| `no_duplicate_commands`       | `domain.aggregates[].commands`                                | `unique_across`   | `Duplicate command name: {name} (in {parent})`                                                   |
| `distinct_reference_aliases`  | `domain.aggregates[].references`                              | `distinct_aliases`| `{parent} has {count} references to {target} with duplicate alias {name:?} — add \`as: :<alias>\` to each so they have distinct names` |

The seven rules are composed into `validate(domain) -> Vec<String>` by a
`Validate` fixture row declaring `rule_order`:
`unique_aggregate_names,aggregates_have_commands,command_naming,valid_references,valid_policy_triggers,no_duplicate_commands,distinct_reference_aliases`.
The generator emits each rule's function body and the composed `validate`.

### §3.2 Lifecycle rules (`lifecycle_validator_shape`)

One rule family. The lifecycle validator walks every aggregate with a
lifecycle block and checks that each declared transition has at least one
command that can fire it, that every terminal state is reachable, and that
no `given` guard references a command argument the command doesn't declare.
The validator emits a `Report` with `errors`, `warnings`, and a strict-pass
flag.

### §3.3 Duplicate-policy rule (`duplicate_policy_validator_shape`)

One rule. A policy is *duplicate* if another policy in the domain has the
same `(on, trigger)` pair — even if the policy names differ. The rule
locates each offender by its policy name (and, for cross-domain policies,
its target domain), so the remediation can be localised. The error template
cites both policy names and the clashing pair.

### §3.4 Warning-class rules (`validator_warnings_shape`)

Two rules, emitted as warnings (non-blocking but visible):

| Rule name                    | Check                                                               | Threshold | Message template (abridged)                                      |
|------------------------------|---------------------------------------------------------------------|-----------|------------------------------------------------------------------|
| `aggregate_count_warning`    | `count(domain.aggregates) > threshold`                              | 7         | `⚠ domain '{}' has {} aggregates; consider splitting`            |
| `mixed_concerns_warning`     | graph components over `reference_to ∪ policy edges`, count ≥ thresh | 5         | `⚠ domain '{}' has {} disconnected concern clusters: {}`         |

The second rule captures a subtler DDD smell: a domain with many aggregates
*and* no connecting references or policies is typically two bounded contexts
trying to share a file. The warning names the clusters.

### §3.5 Total

The twelve rules are: seven core structural (§3.1) + lifecycle coverage and
reachability (§3.2, one family counted as one rule) + duplicate policies
(§3.3) + the two warnings (§3.4) + the `Validate` composition itself. The
count is descriptive, not load-bearing; the point is that every rule is
expressed as data, and the data fits in four `.fixtures` files smaller than
the validator they generate.

---

## §4 Remediation-First Error Format

Every rule carries an `error_template` (or `message_template` for warnings)
that includes a concrete remediation. The difference between a bug-report
framing and a fix-next-edit framing is structural: the template names the
parent structure, the offending element, and — crucially — the next edit.

Example:

```
Account has 2 references to Customer with duplicate alias :customer —
add `as: :<alias>` to each so they have distinct names
```

The developer reads this and their hands move to the file. They don't have
to diagnose the problem; the problem has been diagnosed for them. They type

```ruby
reference_to Customer, as: :owner
reference_to Customer, as: :beneficiary
```

and the error clears on the next parse.

The framing is deliberate. A validator that says `distinct_reference_aliases
failed` teaches the developer how to re-read the framework's codebase. A
validator that says `add \`as: :<alias>\` to each so they have distinct
names` teaches the developer how to fix their domain. The second has a lower
ongoing cost.

---

## §5 Shape-as-Data Declaration

The twelve rules live in four `.bluebook` + `.fixtures` pairs, one per
validator group. The `.bluebook` declares the shape — the signature and
structural contract of each rule function. The `.fixtures` declares the
rows that parameterise that shape. The generator reads both and emits Rust.

A representative row from `validator_shape.fixtures`:

```ruby
fixture "DistinctReferenceAliases",
  name:            "distinct_reference_aliases",
  rust_fn_name:    "distinct_reference_aliases",
  description:     "When an aggregate has multiple reference_to the same "\
                   "target, each must carry a distinct as: alias — "\
                   "otherwise downstream consumers (event payloads, "\
                   "generated form fields, Ruby/Rust routing) can't tell "\
                   "the references apart",
  inspects:        "domain.aggregates[].references",
  check_kind:      "distinct_aliases",
  error_template:  "{parent} has {count} references to {target} with "\
                   "duplicate alias {name:?} — add `as: :<alias>` to each "\
                   "so they have distinct names",
  applied_to:      "aggregate"
```

The declaration is the specification. The generator reads the declared
`check_kind` and emits the Rust body from a known family: `unique` becomes a
`BTreeSet` pass; `non_empty` becomes a count check; `first_word_verb` becomes
a POS lookup plus a regex; `reference_valid` becomes a name-table join;
`distinct_aliases` becomes a group-by. When a rule's check isn't in the
family (a graph-components pass, say, or a lifecycle reachability walk), an
`embedded` body strategy with a `snippet_path` field points at a `.rs.frag`
file carrying the hand-written body. The snippet files are separate from the
shape so that adding a rule does not require editing the shape's Rust.

The generator pipeline is:

```
validator_shape.bluebook + validator_shape.fixtures   (L0: source)
        │
        ▼
canonical IR                                           (L1)
        │
        ▼
Rust module skeleton per shape                         (L6: rust_ir)
        │
        ▼
validator.rs with GENERATED FILE header                (L7)
```

The emitted file carries the regeneration command in its header so that a
reviewer looking at the file knows where to edit upstream:

```text
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/validator_shape/
//! Regenerate: bin/specialize validator
//! Contract:  specializer.hecksagon :specialize_validator shell adapter
//! Tests:     hecks_life/tests/validator_rules_test.rs
```

The integration tests that exercise the rules
(`hecks_life/tests/validator_rules_test.rs`) live in a separate file from the
generated module, so the test/validator relationship is not circular: tests
consume the module as a black box.

### §5.1 Byte-identical regeneration

A golden test at `hecks_life/tests/specializer_golden_test.rs` asserts that
regenerating the validator from its shape produces a byte-identical file to
the one checked into the tree. This is stronger than functional equivalence.
It means the shape-as-data declaration is the single source of truth, and
any drift between the declaration and the Rust is caught by a diff rather
than by a test that exercises the validator's behaviour.

The practical effect is that the generator itself is a first-class target
for validation: if a generator refactor changes the emitted Rust, the
golden test fails and a reviewer sees the diff before the change lands. The
twelve rules stay fixed; their implementation evolves.

---

## §6 Worked Example

A developer opens a fresh bluebook:

```ruby
Hecks.bluebook "Finance" do
  aggregate "Account" do
    reference_to Customer
    reference_to Customer
    command "Account" do
      attribute :amount, Integer
    end
  end
end
```

Running `hecks verify` produces:

```
✗ Account has 2 references to Customer with duplicate alias :customer —
  add `as: :<alias>` to each so they have distinct names
✗ Command Account in Account starts with 'Account' which looks like a
  proper noun — commands should start with a verb
✗ Account references unknown aggregate: Customer
```

Three rules fired. The errors arrive together, in a deterministic order
(`rule_order` from the `Validate` fixture), and each points at its fix. The
developer edits:

```ruby
Hecks.bluebook "Finance" do
  aggregate "Customer" do
    command "RegisterCustomer" do
      attribute :name, String
    end
  end

  aggregate "Account" do
    reference_to Customer, as: :owner
    reference_to Customer, as: :beneficiary
    command "OpenAccount" do
      reference_to Customer
      attribute :initial_balance, Integer
    end
  end
end
```

and `hecks verify` is clean in 0.27 s. The transition from three errors to
clean is three edits, zero framework-internals knowledge required.

---

## §7 Related Work

**Static linters on the production code.** Tools like RuboCop, ESLint,
and `clippy` operate after a production implementation exists. The check
runs against generated Ruby/Rust, not against the domain declaration. A
linter can catch `Command` as a command name with a rule against
non-verbs-as-method-prefixes, but it cannot catch `reference_to Customr`
unless Customer is already an imported symbol — which requires a compiled
codebase.

**Schema validators.** JSON Schema, Protobuf, Avro, and friends validate
serialised data against declared shapes. They are a different scope:
schemas describe data at the wire, not the rules that govern a
well-designed domain.

**DDD-focused tooling.** Several frameworks (Axon, EventFlow, Akka
Persistence) enforce *runtime* DDD constraints: a command dispatched
against an aggregate with no matching handler fails at boot or at first
dispatch. None known to the author emit at parse time with remediation
hints attached to each rule.

**Compile-time policy checkers.** Rust's type system and Scala's tooling
can enforce some DDD patterns at the type level — e.g. sealed command
hierarchies, typed event projections. The cost is that the rules must be
expressed in the host language's type vocabulary, which limits what can be
checked (aggregate counts, naming conventions, and graph-shape properties
do not fit naturally).

**Domain-specific compilers with validators.** MDE tooling (EMF, Xtext,
MPS) has declarative constraint languages (OCL, Check). Hecks differs in
scale (twelve rules, not a general constraint language), in error framing
(remediation-first), and in generator path (the validator itself is a
generated Rust module emitted from a `.bluebook` shape, rather than a
validator embedded in the workbench).

---

## §8 Techniques and Novel Claims

1. **Remediation-first error templates for domain validation.** Every rule's
   `error_template` names the fix, not only the failure. `{parent} has
   {count} references to {target} with duplicate alias {name:?} — add \`as:
   :<alias>\` to each so they have distinct names` is the reference pattern.
2. **Twelve structural/lifecycle/warning rules declared as shape-only data.**
   `hecks_conception/capabilities/validator_shape/`,
   `lifecycle_validator_shape/`, `validator_warnings_shape/`,
   `duplicate_policy_validator_shape/`.
3. **Check-kind family with body-strategy fallback.** `unique`, `non_empty`,
   `first_word_verb`, `reference_valid`, `trigger_valid`, `unique_across`,
   `distinct_aliases`, `count_threshold`, `graph_components` are the
   declared families; rules outside the family declare
   `body_strategy: "embedded"` with a `snippet_path` to a `.rs.frag`.
4. **GENERATED FILE header on every produced validator module.** The header
   cites the source shape directory, the regeneration command, the contract
   (hecksagon shell adapter), and the tests file. The header is the
   reviewer's entry point for upstream edits.
5. **Byte-identical golden-test regeneration.** The generator is itself
   validated by a test that the emitted Rust byte-equals the checked-in
   artifact — so shape and code can never drift silently.
6. **Validator composition as a declared rule order.** The top-level
   `Validate` fixture names `rule_order` as a comma-separated list; the
   generator emits the `validate(domain)` function body in that order so
   error messages appear deterministically.
7. **Warning vs. error separation at the fixture layer.** The warning
   validators emit `Option<String>`; errors emit `Vec<String>`. A
   `Report` in the lifecycle validator carries both and a strict-pass flag.
   The distinction is declared at the shape layer, so a later change of a
   warning to an error is a one-field edit.
8. **Separated test file to break circular dependency between validator and
   its tests.** `hecks_life/tests/validator_rules_test.rs` lives outside
   the generated module; the validator is a black box to its suite.
9. **Under-a-third-of-a-second validator suite at corpus scale.** The full
   twelve-rule suite runs against the chapter bluebooks (620+ aggregates
   across 12 chapters) in under 0.3 s, so it is suitable for a pre-commit
   hook. Speed enforced by the test-speed hook at
   `bin/git-hooks/pre-commit`.

---

## §9 Conclusion

DDD validation does not need a workbench, a type system, or a runtime
boot-phase to be effective. Twelve rules, expressed as data, composed in a
declared order, emitted with remediation hints, and regenerated
byte-identically from their shapes, are enough to catch the design errors
that code review catches inconsistently. The technique is reproducible from
the public repository at commit `c4a903f3` and the artefacts under
`hecks_conception/capabilities/*validator*_shape/` and
`hecks_life/src/*validator*.rs`. We place the technique in the public record
as prior art.
