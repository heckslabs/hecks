# Behavioral Tests

Hecks generates behavioral tests for every bluebook automatically. The
tests run in pure memory — no hecksagon, no adapters, no IO — and use
the same DSL discipline as the source bluebooks.

## The pipeline

```
hecks-life conceive-behaviors path/to/source.bluebook       # generate
hecks-life behaviors          path/to/source_behavioral_tests.bluebook  # run
```

The generator walks the source IR and emits one test per command + one
per query into a sibling `_behavioral_tests.bluebook` file. The runner
boots `Runtime::boot(domain)` (no `data_dir`) and dispatches each test.

## The DSL

```ruby
Hecks.behaviors "Pizzas" do
  vision "Behavioral tests for the Pizzas domain"

  test "AddTopping appends to toppings" do
    setup  "CreatePizza", name: "Margherita", description: "Classic"
    tests  "AddTopping", on: "Pizza"
    input  name: "basil", amount: 5
    expect toppings_size: 1
  end

  test "ByDescription returns matching records" do
    tests  "ByDescription", on: "Pizza", kind: :query
    setup  "CreatePizza", name: "A", description: "classic"
    expect count: 1
  end
end
```

Four keywords inside `test`:

| Keyword  | Purpose |
|----------|---------|
| `tests`  | Required — names the command (or query, with `kind: :query`) under test |
| `setup`  | Zero or more — arrange-phase commands run before the test command |
| `input`  | The act-phase command/query arguments (no IDs — references inject from in-scope) |
| `expect` | Final-state assertions: `<attr>: value`, `<attr>_size: n`, `count: n`, `refused: "msg"` |

The bluebook layer is **id-free**. The runner maintains a per-test
in-scope map (aggregate type → id) populated by setups and consumed
when injecting reference kwargs to dispatch. Test authors never type
`pizza: 1` or `order: 1` — they speak the domain.

## Validators

Three commands gate bluebook health:

```bash
hecks-life check-lifecycle <bluebook>          # transitions, givens, mutation refs
hecks-life check-io        <bluebook>          # bluebook stays in-memory
hecks-life check-all       <bluebook>          # both at once
```

Add `--strict` to promote warnings to errors.

### `check-lifecycle`

Catches structural contradictions:

- **Unreachable from_state** — a transition's `from:` value isn't the
  lifecycle default and isn't the to_state of any other transition. The
  transition is dead code.
- **Stuck default** — the lifecycle has transitions but none can fire
  from the default. Aggregate is permanently stuck (warning).
- **Unreachable given** — `given { status == "X" }` where no command
  produces that state.
- **Mutation references undefined symbol** — `then_set :event, to: :event`
  where the command has no `:event` attribute or reference. The field
  stays null at runtime.

### `check-io`

Asserts the bluebook is pure-memory:

- **Static IR scan** — flags IO-suggestive command names (`Deploy`,
  `Send`, `Push`, `Publish`), past-tense external event names
  (`Deployed`, `Sent`), and pure-side-effect commands (emits but no
  state change, not Create/lifecycle).
- **Runtime smoke** — boots `Runtime::boot(domain)` and dispatches
  every dispatchable command. Lifecycle violations and missing attrs
  are expected (not IO); anything else is a hard error.

## Pre-commit gates

The pre-commit hook (`bin/git-hooks/pre-commit`) blocks commits that:
1. Break Ruby↔Rust parser parity (`spec/parity/parity_test.rb`)
2. Have unreachable lifecycle transitions or givens (`check-lifecycle`)
3. Drift the two conceivers (`tests/conceiver_parity_test.rs`)

Bypass with `PARITY_SKIP=1` or `LIFECYCLE_SKIP=1` — but each is an
antibody failure.
