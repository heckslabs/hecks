---
title: "Cascade Lockdown: An Event-Emission Assertion Pattern for Event-Sourced Systems"
authors: "Chris Young"
version: "paper/prior_use-v1-2026-04-24"
commit: "c4a903f3"
date: 2026-04-24
---

# Cascade Lockdown

## An Event-Emission Assertion Pattern for Event-Sourced Systems

**Version:** `paper/prior_use-v1-2026-04-24`
**Repository commit at time of writing:** `c4a903f3`
**Author:** Chris Young

## Abstract

Event-sourced systems reify state changes as events and react to those
events with policies that dispatch further commands. The test patterns in
common use (dispatch-then-assert-state, record-and-replay snapshotting,
event-store fixtures) either miss the causal ordering of cascading
events or couple tests to storage rather than to the domain's reactive
structure. We describe a testing discipline — *cascade lockdown* — in
which each behavioural test asserts the exact ordered list of events
emitted by a dispatched command, including every event produced by
downstream policy triggers. A cascade walker predicts the expected list
from a declared domain IR; a runtime records the actual list during
dispatch; a simple equality check is the assertion. A change to the
reactive structure of the domain — a new subscriber, a removed policy,
a retargeted trigger — fails every test that exercises the affected
cascade at once. The pattern is presented for adoption outside Hecks:
we describe what it requires from an event-sourced framework, what it
rules out, and a worked example. We place the technique in the public
record as prior art.

---

## §1 Introduction

Event sourcing has matured into a common pattern for DDD-shaped systems
(Fowler, Young, Dahan, Vernon). The pattern offers strong durability,
natural auditability, and a clean separation between the *commands* a
domain accepts and the *events* it produces. A corollary of the pattern
is that domains become *reactive*: once an event is emitted, policies
subscribe to it, trigger follow-up commands, and the follow-up commands
emit further events. A single user-facing action can produce a cascade
of five or ten events across multiple aggregates.

Tests for event-sourced systems have, in the author's practice,
accumulated around three patterns:

1. **Dispatch-then-assert-state.** Dispatch the command, read the
   aggregate's final state, assert against it. This catches many bugs
   but says nothing about the *causal path* the cascade took. A state
   that arrives via the wrong sequence of intermediate events is
   indistinguishable from a correct cascade.
2. **Record-and-replay.** Capture the event log during an integration
   run, snapshot it, and assert equality on future runs. This captures
   the causal path but couples the test to the storage format; a
   refactor to the serialisation layer breaks every test.
3. **Event-store fixture assertions.** Pre-populate an event store with
   a fixture, dispatch, and compare the store's post-state to an
   expected store state. This conflates the domain's behaviour with
   the store's semantics; the test fails both when the domain changes
   and when the store's ordering rules change.

We describe a fourth pattern. Declare the command under test and its
expected ordered event emission list. Dispatch. Assert equality between
the recorded emission list and the declared one. Nothing else is
recorded, no storage is coupled, and the test's domain is the causal
shape of the cascade rather than its storage or final-state
projection.

We call this pattern *cascade lockdown* because a passing test locks
down the shape of the reactive cascade the command triggers. Any change
to a subscribing policy, to a trigger's target command, or to the
ordering guarantees of the policy engine fails every lock-down test that
exercises the affected cascade.

Hecks is the reference implementation and provides the concrete shape
the paper's examples use. The pattern is not specific to Hecks; any
event-sourced framework that (i) distinguishes command dispatch from
policy cascade, (ii) exposes a recordable event bus per dispatch, and
(iii) has a declarable policy graph can adopt it. §6 spells out the
framework requirements.

### §1.1 Contribution

The contributions are:

1. **The cascade lockdown pattern** — asserting the full ordered event
   emission list for a dispatched command, including cascade-produced
   events.
2. **A DSL for the assertion** — `.behaviors` files with
   `expect emits: [E1, E2, ...]` — and a one-to-one runtime that
   consumes them.
3. **A static cascade walker** — a pure function of the domain IR that
   predicts the expected emission list, used for test auto-generation
   and for validator-style warnings.
4. **Two dispatch modes** — `dispatch` (cascade) vs.
   `dispatch_isolated` (no cascade) — so setup phases don't entangle
   with the command under test.
5. **Cycle detection with recursion-stack blocking** — a policy is
   blocked only while on its own recursion stack, which admits diamond
   fan-in patterns (two policies subscribing to the same event) while
   refusing infinite recursion.
6. **A framework-portability section** (§6) listing the requirements
   for adopting the pattern in non-Hecks frameworks.

### §1.2 Paper organisation

§2 is the shape of the problem. §3 describes the DSL. §4 describes the
cycle-detection semantics. §5 describes the static cascade walker. §6
describes the framework requirements for portability. §7 walks an
end-to-end example. §8 surveys related work. §9 enumerates novel claims.
§10 closes.

---

## §2 The Problem: Testing What Cascades

A concrete example. A banking domain has two aggregates, `Loan` and
`Account`, with a policy that funds an account when a loan is issued:

```ruby
policy "DisburseFunds" do
  on  "IssuedLoan"
  trigger "Deposit" do
    map :account_id
    map :principal, to: :amount
  end
end
```

A test that dispatches `IssueLoan` and asserts the account balance
increased catches *functional* correctness — the balance did go up. It
says nothing about:

- Whether the `Deposited` event actually fired on `Account`, or whether
  the balance increased through some other path.
- Whether the `IssuedLoan` event preceded the `Deposited` event.
- Whether any *other* policy also fired on `IssuedLoan` (an audit
  policy, say), producing additional events that the test did not
  assert against.

A refactor that moved the balance update out of the `Deposit` command
and into a direct call during `IssueLoan` handling would keep the
functional test green while silently breaking the event-sourcing
contract. The event log would no longer contain the `Deposited` event
the domain's audit consumers depend on.

The test we want is: "dispatching `IssueLoan` emits exactly
`[IssuedLoan, Deposited]` in that order." A correct implementation
produces that sequence; a refactor that skips `Deposited` fails. The
test's domain is the cascade's causal shape.

---

## §3 The DSL

The `.behaviors` DSL is small. A test declares a command, optional
setup dispatches, optional inputs, and an `expect emits: [...]` list:

```ruby
Hecks.behaviors "Banking" do
  tests "IssueLoan disburses into the linked account" do
    setup  RegisterCustomer: { name: "Ada", email: "ada@example.com" }
    setup  OpenAccount: { customer_id: "{{customer_id}}",
                          account_type: "checking", daily_limit: 1000 }
    input  IssueLoan: { customer_id: "{{customer_id}}",
                        account_id:  "{{account_id}}",
                        principal: 5000, rate: 0.05, term_months: 24 }
    expect emits: [:IssuedLoan, :Deposited]
  end
end
```

The test declares three phases: `setup` is dispatched isolated (no
cascade); `input` is dispatched normally (cascading); `expect` asserts
the exact ordered emission list.

The placeholder syntax (`{{customer_id}}`) is resolved from the setup
phase's emitted events: the first `setup` emits `RegisteredCustomer` and
the `customer_id` is bound from that event's `aggregate_id`; the second
setup's `customer_id` placeholder is resolved before dispatch.

### §3.1 The expect clause locks the cascade

The `expect emits:` clause is the load-bearing assertion. Any change
that adds, removes, or reorders events in the cascade fails the test.
This is both the pattern's strength (precision) and its cost (any
behavioural change in the cascade requires updating every test that
exercises it).

The cost is mitigated by two properties. First, the cascade walker
(§5) auto-generates a baseline test per command, so a change that
legitimately adds a new event can regenerate all affected tests with
one command. Second, the tests read as specifications — a test that
fails points at the exact new event and the exact position, so the
reviewer decides whether the change is intended rather than debugging
whether a test is still relevant.

### §3.2 Two dispatch modes

The runtime exposes two dispatch methods:

- `dispatch(command)` — the normal path. After the command's direct
  event is emitted, the policy engine drains: for each emitted event,
  every subscribed policy is fired, producing further commands whose
  events are appended to the log, and so on until no subscriptions
  remain active.
- `dispatch_isolated(command)` — the setup path. After the command's
  direct event is emitted, the policy engine does not drain. Downstream
  policies are silent.

Both modes share the same command-bus implementation; only the
policy-drain phase differs. The distinction matters because setup
phases in a test must not entangle with the command under test. A test
that issues `RegisterCustomer` as setup and then `IssueLoan` as input
should not have `RegisterCustomer`'s subscribing policies cascading
into the test's expected list. `dispatch_isolated` makes setup local.

---

## §4 Cycle Detection: Recursion-Stack Blocking

Policies can fan in: two policies can subscribe to the same event. They
can also fan out: one policy can trigger a command whose event is
itself subscribed to by another policy, recursively.

A naive cycle-detection rule that blocks a policy from re-entering the
drain would break diamond fan-in. Two policies subscribing to the same
upstream event would either both fire (correct) or only the first would
fire (the bug a simple blocking rule produces).

The correct rule is *recursion-stack blocking*: a policy is blocked
only while it is on its own recursion stack. Once it has finished
firing and been popped from the stack, it is available to re-enter
from a different branch of the cascade. This admits diamonds (two
distinct policies fire from the same upstream) while refusing infinite
recursion (a policy cannot trigger a command whose event it itself
subscribes to without terminating).

Implementation in Hecks:

- Runtime `PolicyEngine` in `hecks_life/src/runtime/policy_engine.rs`
  maintains a `recursion_stack: HashSet<PolicyId>` scoped to the
  drain.
- Static walker in `hecks_life/src/cascade.rs` mirrors the rule on the
  IR: when traversing `emit → policy → trigger` edges, a policy is
  skipped if it is currently on the walker's visit stack.

The two implementations share the rule so that the static prediction
and the runtime behaviour never diverge.

### §4.1 Why the static walker matters

The static walker is a pure function of the domain IR: given an
aggregate and a command, it returns the ordered list of events a
successful dispatch would produce under the recursion-stack rule. This
prediction is:

- The source of auto-generated tests (§5).
- The input to validator-class warnings (mixed-concerns warning, for
  instance, reads the walker's output to detect disconnected clusters).
- The documentation surface: a developer asking "what happens when I
  dispatch `IssueLoan`?" can get an answer without running the
  command.

Because the walker reads the same IR the runtime loads, a change to the
policy declaration changes both the prediction and the runtime's
behaviour. They never disagree in the sense that a valid domain's
prediction and runtime always produce the same list. They *can*
disagree in a pathological case (a bug in one or the other); the
behavioural tests are the cross-check that catches such bugs.

---

## §5 Static Cascade Prediction

The cascade walker at `hecks_life/src/cascade.rs` walks `emit → policy
→ trigger` edges on the parsed IR, applying the recursion-stack rule,
and returns the ordered list of event types.

A `conceive-behaviors` CLI subcommand invokes the walker for every
command in a domain and emits a baseline `.behaviors` file with one
test per command. The baseline:

```ruby
Hecks.behaviors "Banking" do
  tests "IssueLoan cascades" do
    tests "IssueLoan", on: "Loan", kind: :cascade
    setup  RegisterCustomer: { name: "sample", email: "sample" }
    setup  OpenAccount: { customer_id: "sample", account_type: "sample",
                          daily_limit: 0 }
    input  customer_id: "sample", account_id: "sample",
           principal: 0.0, rate: 0.0, term_months: 0
    expect emits: ["IssuedLoan", "Deposited"]
  end
end
```

The baseline's setup dispatches are derived from the reference graph:
any aggregate the cascade touches has a `Create*` setup auto-emitted.
The input values are sample placeholders — the developer replaces them
with realistic values — but the `expect emits:` list is already
correct, because it was produced by the same walker the runtime mirrors.

### §5.1 Regenerating the baseline after a cascade change

When a policy is added or retargeted, the baseline is out of date. The
developer re-runs `conceive-behaviors` and gets a new baseline with
the new expected list. They compare the baseline to the previous
version (a `git diff`) to decide which changes are intentional. Tests
that exercise the changed cascade are regenerated; tests that don't
touch it are unchanged.

This is different from snapshot testing. Snapshot tests capture the
*observed* output and ask the developer to approve it. Cascade-lockdown
tests capture the *predicted* output; the walker predicts before any
run. If the prediction and the run disagree, the test fails; if the
prediction and the developer's intent disagree, the developer updates
the policy declaration.

---

## §6 Framework Requirements for Portability

The cascade-lockdown pattern is not specific to Hecks. Any
event-sourced framework can adopt it if its runtime and IR meet the
following requirements. We list them so a reader considering the
pattern for their own framework knows what to check.

**R1. Distinct command dispatch and policy cascade.** The framework
must expose (or allow access to) a dispatch mode that emits only the
command's direct event and suppresses the cascade, alongside a mode
that cascades. Most mature event-sourced frameworks support this — at
minimum for unit tests. If the framework conflates the two, a `setup`
phase cannot avoid entangling with `input`.

**R2. Per-dispatch recordable event bus.** The runtime must record
the ordered list of events emitted during a dispatch. Per-dispatch
rather than per-aggregate, because the cascade crosses aggregates.
Per-dispatch rather than per-session, because two tests in the same
session must produce independent records.

**R3. Declarable policies.** The reactive structure must be declared
— as code, YAML, DSL, or annotations — rather than emerging from
subscribe-calls at runtime. A framework in which policies are
registered via `event_bus.subscribe(...)` *can* adopt the pattern, but
the static walker becomes harder to write because the subscription
list is only known at runtime. Hecks's `policy` blocks in `.bluebook`
files are the declared form.

**R4. Deterministic policy ordering.** If two policies subscribe to
the same event, the order in which they fire must be deterministic.
The `expect emits:` clause is an ordered list; a non-deterministic
framework produces tests that flake. Hecks sorts subscribers by policy
name within an emission, giving a stable order.

**R5. Cycle-safe drain.** The framework's drain must not loop forever
on a policy that emits an event whose subscriber includes itself.
Recursion-stack blocking (§4) is the rule Hecks uses; a framework
with weaker guarantees (e.g. a fixed-iteration cap) will break some
legitimate diamond patterns and produce non-deterministic tests.

**R6. Optional: static cascade prediction.** The auto-generation
feature of §5 requires a walker that reads the declared policies and
returns an ordered emission list. This is not strictly necessary for
adoption — tests can be hand-written — but without it the ongoing
cost of maintaining tests is higher.

Frameworks meeting R1–R5 can adopt the pattern directly. Frameworks
meeting only R1–R4 can adopt a less powerful variant (hand-written
tests, no auto-generation). Frameworks failing R1 or R2 cannot adopt
the pattern without runtime modification.

---

## §7 Worked Example: ShedDomain in Miette

A concrete instance from Hecks's own codebase. Miette is a long-running
agent whose domain is declared in `hecks_conception/aggregates/`. Its
`Being` aggregate carries a `ShedDomain` command whose cascade crosses
multiple aggregates.

The test:

```ruby
test "ShedDomain cascades through policy chain" do
  tests "ShedDomain", on: "Being", kind: :cascade
  setup  "ConceiveBeing", name: "sample", vision: "sample"
  setup  "ConnectNerve", name: "sample", from_domain: "sample",
         from_event: "sample", to_domain: "sample", to_command: "sample"
  input  domain_name: "sample"
  expect emits: ["DomainShed", "NerveSevered", "NerveConnected"]
end
```

The runner executes the test in five steps:

1. **Boot.** `Runtime::boot(domain)` loads the `Being` bluebook;
   repositories, event bus, policy engine, and projections are
   constructed in-process with no adapters required.
2. **Setup.** `ConceiveBeing` and `ConnectNerve` dispatch isolated.
   Each emits its direct event; neither cascades.
3. **Input.** `ShedDomain` dispatches normally. The policy engine
   drains: the direct emission `DomainShed` fires both
   `SeverOnShed` (trigger `SeverNerve`) and `DetectDriftOnShed`
   (trigger `ConnectNerve`).
4. **Record.** The event bus records
   `[DomainShed, NerveSevered, NerveConnected]`.
5. **Assert.** The runner checks equality against the declared list.

The three events correspond to the cascade's stages:

- `DomainShed` — direct emission from the `ShedDomain` command on
  `Being`.
- `NerveSevered` — from the `SeverNerve` command, triggered by the
  `SeverOnShed` policy.
- `NerveConnected` — from the `ConnectNerve` command, triggered by
  the `DetectDriftOnShed` policy (a second policy fanning out from the
  same upstream event).

The chain is a diamond at the `DomainShed` vertex: two distinct
policies subscribe to it. The recursion-stack rule admits the diamond —
both branches fire exactly once in a deterministic order.

The static walker at `hecks_life/src/cascade.rs` predicts the same
ordered list by walking `emit → policy → trigger` edges on the parsed
IR. A test in this shape is therefore a compile-time prediction
codified as a runtime assertion.

If a subsequent commit adds a new subscriber to `DomainShed`, changes
the trigger of `SeverOnShed` from `SeverNerve` to `SeverNerveAndLog`,
or moves one of the policies out of the `Being` bluebook, the assertion
fails. The test does not merely check that `ShedDomain` succeeded; it
locks down the reactive structure of the domain as declared.

---

## §8 Related Work

**Given-When-Then for event-sourced aggregates.** The canonical pattern
(Vaughn Vernon, Greg Young) dispatches a command after a pre-populated
event history and asserts against the post-event history. The shape is
similar: events in, events out. The difference is scope — GWT typically
asserts the *new* events produced by the aggregate under test, not the
downstream cascade. Cascade lockdown extends the assertion to include
policy-triggered events across aggregates.

**Snapshot testing.** Jest, rspec-snapshot, cypress snapshots. Snapshot
tests capture observed output and prompt the developer to approve
diffs. Cascade lockdown differs in that the *prediction is static* —
the cascade walker produces the expected list before any dispatch —
and the assertion is equality against the prediction. No approval step
is required; the declared domain is the source of truth.

**Event-store fixtures.** EventStore, Marten, Axon test harnesses that
assert against the post-state of the store. These are storage-coupled;
a change to how events are stored breaks tests even if the domain's
behaviour is unchanged. Cascade lockdown asserts against the dispatched
emission list, which is upstream of storage.

**Property-based testing of state machines.** Hypothesis, QuickCheck
model-based tests for aggregates. These generate random command
sequences and check invariants. A useful complement to cascade lockdown
— PBT catches whether a command sequence preserves invariants; cascade
lockdown catches whether a single command's cascade matches the
declared reactive shape. The two answer different questions.

**Process-algebra verification.** Spin, TLA+ for checking concurrent
message-passing systems. Heavy for day-to-day event-sourcing tests, but
a superset: a model checker can verify cascade equality as one property
among many. Cascade lockdown is the lightweight, in-suite shape of the
property.

**Service-virtualisation (VCR, Mountebank).** Record-and-replay
HTTP interactions. Cascade lockdown's spirit — declare exactly what
happens, fail on drift — is similar. The scope differs: VCR operates at
the HTTP boundary; cascade lockdown operates at the domain boundary.

---

## §9 Techniques and Novel Claims

1. **Cascade lockdown as a testing discipline.** Assert the full
   ordered event emission list for a dispatched command, including
   cascade-produced events. `expect emits: [E1, E2, ...]`.
2. **A minimal DSL for the assertion.** `.behaviors` files with
   `setup`, `input`, `expect` clauses and placeholder binding via
   `{{name}}`.
3. **Two dispatch modes in the runner.** `dispatch` cascades;
   `dispatch_isolated` does not. Setup phases use the latter so they
   don't entangle with the command under test.
4. **Recursion-stack blocking for policy cycle detection.** A policy
   is blocked only while on its own recursion stack; diamond fan-in is
   admitted. Implemented identically in `hecks_life/src/cascade.rs`
   (static walker) and `hecks_life/src/runtime/policy_engine.rs`
   (runtime).
5. **Deterministic policy ordering** by policy name within a single
   emission, so `expect emits:` lists are stable.
6. **Static cascade walker over the declared IR.** Predicts the
   expected emission list as a pure function of the domain
   declaration; used for auto-generation and for mixed-concerns
   warnings.
7. **Baseline test auto-generation.** `conceive-behaviors` walks
   every command and emits a default `.behaviors` file with correct
   `expect emits:` lists derived from the walker.
8. **Framework-portability requirements.** R1 through R6 list the
   specific runtime and IR properties a non-Hecks framework needs to
   adopt the pattern.
9. **Event log as audit trail of causal shape.** Because every
   dispatch records its emission list, and every lockdown test asserts
   against that list, the event log is a byte-accurate record of the
   causal shape the domain has committed to — a shape the tests
   exercise on every commit.

---

## §10 Discussion

### §10.1 When the pattern is wrong

Cascade lockdown is wrong for domains whose reactive structure is
deliberately nondeterministic. A notification policy that randomises
its recipient order, or a batch-processing policy whose emission order
depends on external scheduling, will produce nondeterministic event
lists. Lockdown tests flake or fail under such domains.

The remedy is to write the policy differently: emit a deterministic
event (`NotifyRequested` with a recipient list) and let the nondeterministic
behaviour happen in a downstream adapter that is not asserted against.
The adapter's order is not part of the domain's reactive structure; the
domain's reactive structure is the `NotifyRequested` emission. In
practice this factoring is a good idea regardless — it separates
*what the domain says happened* from *how the outside world reacts*.

### §10.2 When the pattern is overkill

A domain with no policies — a pure CRUD domain where every command
emits one event and nothing subscribes — has no cascade to lock down.
Cascade lockdown reduces to "assert one event was emitted," which is
the standard given-when-then shape. The technique buys nothing over
GWT in this case, and the `.behaviors` boilerplate is arguably
overhead. The pattern pays off when the cascade is non-trivial.

### §10.3 On the VCR-ness of the pattern

Cascade lockdown is spiritually VCR-like: a declared record, a
replayed dispatch, an equality check. The distinction is that the
declared record is *computed* from the domain declaration, not
captured from an observation. This makes the record *tractable to
review* — the developer reads the expected emission list and compares
to their mental model of the domain, rather than reading an opaque
snapshot and hoping it still reflects their intent. A VCR cassette
decays because the observer decays; a cascade-lockdown expectation
decays only when the domain changes, and the walker makes the decay
visible.

---

## §11 Conclusion

Cascade lockdown is a testing discipline for event-sourced systems
that asserts the full ordered emission list of a dispatched command,
including cascade-produced events. It is implementable in any
event-sourced framework that meets six runtime and IR requirements;
Hecks is the reference implementation. The technique catches structural
regressions in the domain's reactive shape that functional tests miss
and does so without coupling to storage or to snapshot approval. We
place the technique in the public record as prior art at commit
`c4a903f3`. The reference implementation is at
`hecks_life/src/cascade.rs`, `hecks_life/src/runtime/policy_engine.rs`,
and the `.behaviors` files under `hecks_conception/`.
