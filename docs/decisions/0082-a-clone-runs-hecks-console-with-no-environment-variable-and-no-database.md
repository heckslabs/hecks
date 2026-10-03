# A clone runs `hecks console` with no environment variable and no database

**Status:** Proposed. Date: 2026-10-02. [ADR 0073](0073-the-newcomer-path-is-a-memory-default-console-and-a-short-readme.md) promised a console that needs no database; the 3.0 launcher no longer keeps that promise, and the docs now say what actually works.

## Context

ADR 0073 made a bare `bin/console` boot pizzas on Memory. Since then `exe/hecks` (ADR 0066) has become a generated launcher that opens the Hecks domain itself before it runs any verb, including `console`. Checked on 3.0.3:

- `bundle exec hecks console`, the command the README and CONTRIBUTING gave, stops with `can't find executable hecks for gem hecks`, because the Gemfile has no `gemspec` line.
- `bundle exec exe/hecks console` stops with `cannot bind PostgresEra at postgres://hecks@localhost/hecks`, because `lib/hecks/hecks/hecks.world` sets `default_adapter "PostgresEra"` for the Hecks domain's own journal.
- `HECKS_ENVIRONMENT=memory bundle exec exe/hecks console` works: pizzas on Memory, no database, `git status` clean.

The README, getting-started and CONTRIBUTING now give the third form. A newcomer must still know to set the variable, and the failure message does not name it.

## Decision

1. Add `gemspec` to the Gemfile so `bundle exec hecks` resolves in a clone.
2. Make `console` (and only the verbs that open no journal worth keeping) boot the Hecks domain on Memory without the variable, so the first command is `bundle exec hecks console`.
3. Make the PostgresEra bind failure name `HECKS_ENVIRONMENT=memory` as the way out.

## Consequences

- The quickstart shrinks to the command it was written as.
- `console` journals nothing across restarts. That matches the pizzas console, which is already in-memory.
- Adding `gemspec` changes what Bundler resolves for every contributor and for CI. It needs a full-suite run before it is accepted.

## Alternatives considered

- **Docs only (what shipped).** No risk, but the first command carries an unexplained variable.
- **A `bin/console` wrapper.** Restores the old command but reintroduces the dev-tooling split ADR 0066 removed.

## Open items

- Which other verbs, if any, should default to Memory?
- Does `gemspec` in the Gemfile alter the pinned `json` or the pre-push hooks' behavior?
