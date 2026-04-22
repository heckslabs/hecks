# Plan — i43: cross-bluebook `.behaviors` dialect (`loads`)

## 1. Current state + why the gap hurts

The `.behaviors` runner (Ruby `bin/hecks-behaviors` + Rust `hecks-life behaviors`)
boots ONE `Domain` per test from a single `.bluebook` source. Its cascade
engine (`PolicyDrain` / `drain_policies`) will follow policies to any
aggregate **inside that domain**, but `across "Pulse"` hops to a policy
defined in a *sibling* bluebook are invisible — the sibling file was
never parsed, its policies are not in `domain.policies`, and the event
goes nowhere.

Coverage grid today:

|                                          | single-bluebook cascade | cross-bluebook cascade |
|------------------------------------------|-------------------------|------------------------|
| `.behaviors` `expect emits: [...]`       | ✓ (PR #261 era)         | ✗ (retires the PR)     |
| `bash tests/*_smoke.sh`                  | redundant               | ✓ (the workaround)     |
| Ruby/Rust parity (`spec/parity/...`)     | ✓                       | n/a                    |
| Generator static prediction              | ✓                       | ✓ (already crosses)    |

PR history this plan resolves:

- **PR #261** — moved `BodyPulse` fan-out behind `across "Pulse"`.
- **PR #277** — narrowed `mindstream.behaviors` to `["Ticked"]` because
  the single-bluebook runner can't see `Pulse.Emit` fire.
- **PR #282** — shipped `tests/pulse_fanout_smoke.sh` (106 LoC shell)
  to recover end-to-end coverage.
- **PR #281** — added auto-loading of sibling `.fixtures`.

`BodyPulse` subscribers (grep of `on "BodyPulse"`): 15+ downstream
policies across `sleep`, `body`, `being`, `mindstream`, `status_bar`,
`heart`. One test file that can't see any of them. The shell script is
the scar tissue this plan removes.

## 2. Chosen syntax

```ruby
Hecks.behaviors "Mindstream" do
  vision "..."
  loads "body", "being", "sleep", "pulse"   # NEW — zero or more

  test "Tick fans out across the body" do
    tests "MindstreamTick", on: "Tick", kind: :cascade
    then_events_include "BodyPulse", "FatigueAccumulated",
                        "SynapsesPruned", "NerveConnected"
  end
end
```

### Design decisions

1. **Keyword `loads`** (plural verb, plural args). Matches Ruby DSL idiom.
   Rejected alternatives: `includes` (conflicts with Ruby `include`),
   `spans` (too abstract), `imports` (not DSL-native).

2. **String resolution: file-system-adjacent, not registry.**
   `loads "pulse"` looks for:
   1. `<dir(test_file)>/pulse.bluebook` — sibling file (dominant case)
   2. `<cwd>/aggregates/pulse.bluebook` — catalog-level
   3. Hard-error with a useful message naming both paths tried

   No `.world` config, no env var. File system IS the registry.

3. **Own-aggregate not repeated.** `mindstream.behaviors` still loads
   `mindstream.bluebook` implicitly by naming convention. `loads "pulse"`
   adds pulse on top.

4. **New assertion: `then_events_include`, set-membership.**
   Cross-bluebook cascades hop through N policies whose relative ordering
   is a runtime-drain-order detail, not a semantic contract. Set membership
   avoids flakes on incidental ordering changes. Superset is fine.

5. **`expect emits: [...]` preserved unchanged** (order-strict, intra-aggregate).

6. **No change to `tests ..., kind: :cascade`.** Orthogonal to `loads`.

### Alternatives rejected

- `.world`-file config with bluebook glob — too much machinery, violates locality.
- Global bluebook registry loaded once per process — bad for parallel tests.
- Auto-discover by event name — magic, hard to reason about.

## 3. Runner changes

### 3.1 Ruby — `lib/hecks/behaviors/runner.rb`

Extend `Runner.run` with `extra_bluebooks:` keyword arg. In `run_one`,
compose a single `Domain` by concatenating `.aggregates`, `.policies`,
`.value_objects`, and `.queries` from each loaded bluebook.

Collision detection: aggregate name appearing in two loaded bluebooks
is a hard error.

~40 LoC + ~15 LoC helper in `lib/hecks/behaviors/domain_merger.rb`.

### 3.2 Rust — `hecks_life/src/behaviors_runner.rs`

Mirror: `extra_sources: &[&str]` parameter. In `run_one`:

```rust
let mut domain = parser::parse(source_text);
for extra in extra_sources {
    let extra_domain = parser::parse(extra);
    domain.aggregates.extend(extra_domain.aggregates);
    domain.policies.extend(extra_domain.policies);
    domain.value_objects.extend(extra_domain.value_objects);
}
```

~50 LoC + collision helper.

### 3.3 CLI glue

- `bin/hecks-behaviors`: after loading the test file, resolve each name
  in `Hecks.last_test_suite.loads` via `DomainMerger.resolve_path`,
  pass loader callbacks to `Runner.run`.
- `hecks_life/src/main.rs`: same resolution, pass `&[String]` source
  texts to `run_suite_with_fixtures_and_loads`.

### 3.4 Event-bus behavior

`PolicyDrain` (Ruby) and `drain_policies` (Rust) walk
`domain.policies` matching on `ev[:name]`. With merged domain, cross-
bluebook hops drain automatically, zero runtime changes beyond domain
composition. The `across "X"` marker stays metadata (parsed but unused
at drain time — already the case today).

## 4. Parser changes

### 4.1 Ruby — `lib/hecks/dsl/test_suite_builder.rb`

```ruby
def loads(*names)
  @loads.concat(names.map(&:to_s))
end
```

Add `loads` field to `lib/hecks/bluebook_model/structure/test_suite.rb`.
Add `then_events_include` DSL method to `lib/hecks/dsl/test_builder.rb`.

### 4.2 Rust — `hecks_life/src/behaviors_parser.rs`

Extend top-level parser:

```rust
else if line.starts_with("loads") {
    for name in extract_all_strings(line) {
        suite.loads.push(name);
    }
}
```

Extend `interpret_test_line` with `then_events_include` → new
`test.events_include: Vec<String>`.

### 4.3 IR

- `TestSuite.loads: Vec<String>` (Rust) / `Structure::TestSuite#loads: Array<String>` (Ruby)
- `Test.events_include: Vec<String>` / `Test#events_include`

## 5. Event-log design — global, not per-bluebook

Current event bus is already a single ordered `Vec<Event>` on
`Runtime`. It's oblivious to which bluebook a policy came from.
That's exactly right with merged domain.

`pre_event_count` snapshot marks the boundary: any event with
index >= pre_event_count fired in response to the test command.
`then_events_include` applies same skip, set membership only considers
in-scope events.

Per-bluebook logs with cross-refs rejected — YAGNI for the assertion
primitives. Could tag events with source-bluebook later if debugging
demands it.

## 6. Setup chains across bluebooks

PR #281 already auto-loads each bluebook's sibling `.fixtures`. With
merged domain, fixtures concatenate into the same repositories map
(keyed by aggregate name). Cross-bluebook cascade finds pre-seeded
records naturally. No new explicit-setup DSL pressure.

## 7. Parity contract

New fixture set: `spec/parity/behaviors/`:

- `01_single.bluebook` + `.behaviors` — no `loads`, baseline.
- `02_loads/two_aggregates.bluebook` — primary.
- `02_loads/sibling.bluebook` — loaded sibling with cross-bluebook policy.
- `02_loads/two_aggregates.behaviors` — uses `loads "sibling"`, asserts
  cross-bluebook cascade via both `expect emits:` and `then_events_include`.
- `03_fixture_seed/` — across-bluebook with `.fixtures` preseeding.

Extend `spec/parity/behaviors_parity_test.rb` to exercise these.
Seed `spec/parity/behaviors_known_drift.txt` empty — any cross-runner
divergence breaks pre-commit.

## 8. Consumer audit

### Reverts

| File | Action | LoC |
|---|---|---|
| `hecks_conception/tests/pulse_fanout_smoke.sh` | DELETE | −106 |
| `hecks_conception/aggregates/mindstream.behaviors` | restore full cascade (PR #277 undo) + add `loads "pulse", "body", "being", "sleep"` | +6 / −2 |

`mindstream.behaviors` replaces `expect emits: ["Ticked"]` with
`then_events_include "Ticked", "BodyPulse", "FatigueAccumulated",
"SynapsesPruned", "NerveConnected"`.

### Coverage gains (opportunity)

Grep of `across "X"` in bluebooks with companion `.behaviors`:

- `awareness.behaviors` — crosses to Dream, StatusBar, Suggestion, Memory, MietteBody
- `interpretation.behaviors` — crosses to Suggestion
- `memory.behaviors` — crosses to Dream
- `conception.behaviors` — crosses to Catalog
- `bulk_generator.behaviors` — crosses to Census
- `console.behaviors` — crosses to Memory
- `catalog/mind.behaviors` — crosses to Dream, StatusBar, Suggestion, Memory

Opportunity, not scope. This plan ships the mechanism; authors add
`loads` as they choose. Mindstream is the only file this plan actively
migrates (to prove the mechanism + delete the shell).

## 9. Commit sequence

| # | Commit | LoC |
|---|--------|-----|
| 1 | `docs(plans/i43)` | +450 |
| 2 | `inbox(i43): reference plan` | ~5 |
| 3 | `feat(behaviors-ir): TestSuite#loads + Test#events_include` | +40 |
| 4 | `feat(behaviors-parser): parse loads + then_events_include` | +80 |
| 5 | `feat(behaviors-dsl): TestSuiteBuilder#loads + then_events_include` | +30 |
| 6 | `feat(behaviors-runner): merge loaded bluebooks into single Domain` | +130 |
| 7 | `feat(behaviors-runner): then_events_include set-membership` | +40 |
| 8 | `test(parity/behaviors): 01_single, 02_loads, 03_fixture_seed` | +100 |
| 9 | `refactor(mindstream.behaviors): restore full cascade via loads` | +6 / −2 |
| 10 | `chore: delete pulse_fanout_smoke.sh` | 0 / −106 |

**Net:** ~426 added, 108 removed.

### Sequencing

- Commits 3–5 can ship as a no-op DSL extension PR if preferred.
- Commit 6 is the load-bearing one; both runners must land together.
- Commit 9 proves value. Commit 10 only after commit 9 is verified green in CI.

## 10. Risks

### R1. Event-ordering flakes in `then_events_include`

Mitigation: document as default for cross-bluebook tests; reserve
strict `emits:` for intra-aggregate ladders.

### R2. Cross-bluebook aggregate name collision

Mitigation: hard error with both source paths. Author renames.

### R3. `pre_event_count` boundary drift from fixture seeding

Mitigation: `FixturesLoader.apply` today uses direct state mutation,
not dispatch. Assert with a unit test: "fixtures seed zero events."

### R4. Re-parsing N bluebooks per test = slowness

Mitigation: measure. Expected <200ms growth. If painful, parse each
once and clone Domain per test. Defer.

### R5. Parity divergence under unusual syntax (symbols vs strings)

Mitigation: normalize to strings on both sides. Parity test uses
strings everywhere.

### R6. Backward compat: files without `loads` must behave identically

Mitigation: explicit test in commit 6 asserts bit-identical verdicts
pre- and post-change for zero-`loads` files.

## 11. Open questions (not blockers)

1. `loads` inside `test` block too? No user demand; keep suite-level only.
2. Namespaced loads (`loads "aggregates/body"`)? Defer — resolve by
   file-walk, hard-error if ambiguous.
3. Should `expect emits:` also skip fixture-seed boundary? Already does.

## 12. Acceptance criteria

- [ ] Both runners accept `loads "X"` in test files
- [ ] `then_events_include` asserts set membership, parity-green
- [ ] `mindstream.behaviors` with `loads` passes on both runners
      (same verdicts as deleted smoke shell)
- [ ] `pulse_fanout_smoke.sh` deleted
- [ ] `spec/parity/behaviors_parity_test.rb` passes with new fixtures
- [ ] Any `.behaviors` file without `loads` produces unchanged verdicts
- [ ] Aggregate-name collision hard-errors with both paths in message

### Critical Files for Implementation

- `lib/hecks/behaviors/runner.rb`
- `hecks_life/src/behaviors_runner.rs`
- `hecks_life/src/behaviors_parser.rs`
- `lib/hecks/dsl/test_suite_builder.rb`
- `hecks_conception/aggregates/mindstream.behaviors`
