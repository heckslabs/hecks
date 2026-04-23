# Nursery Parity Sweep

`bin/nursery-parity-sweep` applies mechanical Gate A and Gate B transformations
across `.bluebook` files to close the Ruby/Rust parser dialect drift tracked in
[`docs/plans/i31_expand_parity_coverage.md`](../plans/i31_expand_parity_coverage.md).

The Rust parser accepts several forms the Ruby parser strictly rejects. This
tool rewrites those files to the strict form — the same form the `aggregates/`,
`capabilities/`, and `catalog/` corpus already use.

## When to run it

- After drafting new `.bluebook` files in `hecks_conception/nursery/` (LLM output
  often uses the permissive form).
- When the parity suite (`ruby -Ilib spec/parity/parity_test.rb`) reports
  soft-drift in the nursery section.
- As a one-shot cleanup after pulling new contributions.

The tool is **idempotent** — running a second time is a no-op once the corpus
is clean. Safe to run repeatedly.

## Usage

```bash
# Sweep the whole nursery (default target)
bin/nursery-parity-sweep

# Dry-run to preview changes without writing
bin/nursery-parity-sweep --dry-run

# Sweep a specific directory or single file
bin/nursery-parity-sweep hecks_conception/nursery/taxidermy
bin/nursery-parity-sweep path/to/one.bluebook
```

Exit status is `0` on success; the tool prints a per-transformation count and a
list of files that were skipped (with the reason).

## Transformations applied

| # | Input | Output | Why |
|---|---|---|---|
| 1 | `reference_to "X"` | `reference_to(X)` | Ruby DSL rejects strings in `reference_to`; bare constant required. |
| 2 | `list_of "X"` (one-line, no block) | `list_of(X)` | Same strictness — `list_of` coerces only bare constants. |
| 3 | `list_of(X) :field` | `attribute :field, list_of(X)` | Gate A swap. Ruby parser does not accept `list_of(…) :field` shorthand; it must ride on an `attribute`. |
| 4 | `list_of "X" do … end` (inline block) | extracted sibling `value_object "X" do … end` | The inline form creates an inline value object at parse time. Ruby's strict parser wants the VO declared explicitly as a sibling, then referenced. |

Transformation 4 is conservative: the block body must contain only `attribute`
lines (comments and blank lines are fine). Blocks containing commands,
policies, lifecycle, or other DSL are left alone and reported in the
"skipped" list for manual triage.

## Example — before

```ruby
aggregate "Field" do
  attribute :name, String
  list_of(WeatherReading) :weather_history
  reference_to "Farm"

  list_of "Reading" do
    attribute :value, Float
    attribute :at, String
  end
end
```

## Example — after

```ruby
aggregate "Field" do
  attribute :name, String
  attribute :weather_history, list_of(WeatherReading)
  reference_to(Farm)

  value_object "Reading" do
    attribute :value, Float
    attribute :at, String
  end
end
```

## Verifying a sweep

After running the tool, confirm the parity count improved:

```bash
bin/nursery-parity-sweep
ruby -Ilib spec/parity/parity_test.rb
```

The nursery section line (`nursery (soft) N/375`) should climb toward 375/375.
Remaining soft-drift after the sweep is by definition outside Gate A/B —
look for Gate C gaps (`fixture`/`lifecycle`/`event` DSL) or Gate D semantic
drift (abbreviation handling, etc.).

## Retirement

This tool retires when:

1. Every nursery file parses cleanly in both runtimes, and
2. New `.bluebook` files are drafted directly in the strict form (via DSL tools
   or validated templates) rather than through permissive LLM output.

Until both are true, run the sweep after any nursery addition and before
flipping the nursery parity section from soft to hard in
`spec/parity/parity_test.rb`.

## See also

- [`docs/plans/i31_expand_parity_coverage.md`](../plans/i31_expand_parity_coverage.md)
  — full plan for closing the nursery coverage gap
- [`docs/usage/cross_target_parity.md`](cross_target_parity.md)
  — the parity suite itself
- `spec/parity/known_drift.txt` — escape hatch for files with intentional drift
