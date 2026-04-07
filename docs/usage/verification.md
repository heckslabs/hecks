# Bluebook Verification

The Bluebook is the spec. No RSpec test files — the chapter definitions
are the test suite. `bin/verify` loads every chapter, validates its IR,
and reports any issues.

## Usage

```bash
bin/verify              # quiet — exits 0 or 1
bin/verify --verbose    # prints each chapter summary
```

Output:

```
  Bluebook: 212 aggregates, 222 commands
  Runtime: 103 aggregates, 133 commands
  ...

16 chapters, 685 aggregates, 865 commands
Bluebook verified.
```

## What it checks

1. Every chapter module loads without error
2. Every chapter has at least one aggregate
3. Every aggregate has a description

If any check fails, it raises `Hecks::Chapters::VerificationError` with
a list of issues.

## Pre-commit hook

The pre-commit hook runs three checks:

1. `bin/verify` — Bluebook self-validation (~0.2s)
2. Smoke test — `ruby -Ilib examples/pizzas/pizzas.rb`
3. Watchers — cross-require, file size, doc reminders

## Programmatic usage

```ruby
require "hecks"
load "HecksBluebook"
require "hecks/chapters/verify"

Hecks::Chapters.verify                  # => true or raises
Hecks::Chapters.verify(verbose: true)   # prints summary
```

## Why no RSpec?

The chapter IR defines what exists. If a chapter loads and its
aggregates have descriptions, the specification is satisfied.
Hand-written tests were testing implementation details — behaviors
that should match the IR by construction, not by assertion.

The Bluebook IS the spec. The compiler IS the test.
