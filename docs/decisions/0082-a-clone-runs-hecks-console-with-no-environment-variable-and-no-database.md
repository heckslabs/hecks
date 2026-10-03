# A clone runs `hecks console` with no environment variable and no database

**Status:** Accepted — implemented. Date: 2026-10-02. [ADR 0073](0073-the-newcomer-path-is-a-memory-default-console-and-a-short-readme.md) promised a console that needs no database; the 3.0 launcher stopped keeping that promise, and this restores it.

## Context

ADR 0073 made a bare `bin/console` boot pizzas on Memory. Since then `exe/hecks` (ADR 0066) has become a generated launcher that opens the Hecks domain itself before it runs any verb, including `console`. Checked on 3.0.3:

- `bundle exec hecks console`, the command the README and CONTRIBUTING gave, stops with `can't find executable hecks for gem hecks`, because the Gemfile has no `gemspec` line.
- `bundle exec exe/hecks console` stops with `cannot bind PostgresEra at postgres://hecks@localhost/hecks`, because `lib/hecks/hecks/hecks.world` sets `default_adapter "PostgresEra"` for the Hecks domain's own journal.
- `HECKS_ENVIRONMENT=memory bundle exec exe/hecks console` works: pizzas on Memory, no database, `git status` clean.

## Decision

1. Add `gemspec` to the Gemfile so `bundle exec hecks` resolves in a clone.
2. Add a `memory_verbs` option to the world's `launcher` setting. The generated `exe/hecks` runs those verbs on the Memory environment unless `HECKS_ENVIRONMENT` is already set; the Hecks world lists only `console`.
3. Make the PostgresEra bind failure say that `HECKS_ENVIRONMENT=memory` is the way out for a domain with a memory overlay.

## Consequences

- The quickstart shrinks to the command it was written as.
- `console` journals nothing across restarts. That matches the pizzas console, which is already in-memory.
- `Gemfile.lock` now carries a `hecks (<version>)` path entry, so a release's version bump must update the lock as well.

## Alternatives considered

- **Docs only (what shipped).** No risk, but the first command carries an unexplained variable.
- **A `bin/console` wrapper.** Restores the old command but reintroduces the dev-tooling split ADR 0066 removed.

## Open items

- Which other verbs, if any, should default to Memory? Verbs that read the journal back (`stores`, `history`) must not.
