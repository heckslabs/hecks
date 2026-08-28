# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Dates are when a change landed on `main`, not when this file was written.
`hecks` is pre-1.0 (see [`docs/1.0-readiness.md`](docs/1.0-readiness.md)) —
entries below are grouped by theme, not itemized commit-by-commit; see
`git log` for the full history.

## [Unreleased]

### Fixed

- **Entity dispatch had no argument gate at all (H1).** Every aggregate
  command and port operation refuses unknown/absent arguments;
  `EntityInterpreter` (an aggregate's own owned pieces — `Account
  .LedgerEntry.Reverse`) silently didn't, on a comment claiming it
  "inherited" a check nothing on its path ever ran. A bogus argument was
  silently accepted; an omitted declared one silently nil'd the field it
  should have set. Fixed, with a correct addressing rule for multi-hop
  entity chains and a pinning spec. (2026-08-27)
- **The property fuzzer only ever ran against the Memory adapter.**
  `bin/fuzz --adapter sqlite|postgres` now runs the full property battery
  against real Sqlite and real Postgres, not just in-memory. Along the
  way, fixed a real bug this surfaced: any Postgres-bound domain with a
  reference-hop query field (`owner/field`) failed to boot at all
  (`PG::UndefinedColumn` in `SchemaBuilder#index_field!`) — previously
  unreachable because nothing had run such a domain against real Postgres
  before. (2026-08-27, PRD 02)
- **`Gemfile.lock` wasn't committed.** The `json` gem was already pinned
  exactly in the `Gemfile`, but every other dependency was free to float
  between CI runs with no diff to review. Committed a lockfile generated
  from a clean `bundle install`. (2026-08-27)
- Era-migration/rekey data-loss findings (H3–H5): deleting an
  era-migrated record no longer resurrects the ancestor era's row in the
  head view; rekey SQL is now folded into the human-approval digest, so
  editing an approved rekey's mapping invalidates the approval; a
  dotted-member `compute` no longer exempts its whole parent attribute
  from the Layer-2 cross-execution equivalence gate. Verified live
  against real Postgres.
- Query engine correctness (H6–H9): `limit`/`offset` ordering across the
  in-memory and reference/entity query engines now matches SQL
  (offset-then-limit, not limit-then-offset); dotted field paths go
  through `FieldPath.dig` everywhere instead of raw hash access; `one_of`
  closed sets are covered by `seal_defaults` (a closed-set attribute with
  a `default:` no longer refuses its own default on create); the
  meta-validator's cache key now incorporates read-model filters, so an
  edited `where`/`order_by`/`limit` can't serve a stale cached filter.
- Routing/deploy correctness (H12–H14): a record id containing `.`
  (e.g. an email-typed identity) now routes correctly instead of 404ing;
  `make deploy` no longer reports failure for a successful Shared-mode
  deploy; `scaffold-translation`/`translation-audit` now refuse by
  default rather than silently scaffolding/auditing the local dev
  database when they'd otherwise miss the intended tunnel.
- Session security (H11): the Rust web layer's session/OAuth-state HMAC
  now refuses to boot on an empty/unset `SESSION_SECRET` instead of
  keying on a publicly-known empty string.
- Systemic query/type-safety root causes (S1–S3): typed query values no
  longer collapse to `.to_s` on the wire; a stored `false` no longer
  reads back as `nil`; identity-value escaping paths reviewed.
- The nested-reaction-dispatch race (`@reaction_depth`) is fixed —
  `Thread.current`-backed, not a shared ivar, safe under a threaded Puma
  deployment.
- 10 real Ruby/Rust parity bugs across the parser, codegen, and kernel,
  including a missing `formerly_known_as` field in the Rust parser that
  broke every `parser_parity`/`codegen_parity`/`rust_conformance`
  fixture that didn't declare it.
- `AppendOnly#record_event`: domain events were never actually persisted.
- A lost-update gap in state-dependent command dispatch.

### Added

- `docs/1.0-readiness.md` — a single, explicit statement of what a `1.0`
  tag will mean, why it isn't tagged yet (blocked on
  [ADR 0025](docs/decisions/0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md),
  a real breaking DSL redesign), and everything else that has to be true
  first.
- `CONTRIBUTING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/`,
  `.github/PULL_REQUEST_TEMPLATE.md`.
- `chess` as a new example domain.
- The universal MCP dispatch door (`dispatch`/`query`/`state`/`catalog`/
  `describe`/`validate`/`history`/`follow`/`behaviors`), renamed
  `Storehouse`.
- `bin/follow` — a live tail of a domain's append-only journal.
- `corrects` — a retroactive-correction DSL command word.
- Generated Mermaid diagrams (`<Aggregate>_surface.mmd`,
  `<ProcessManager>_saga.mmd`, `frameworks.mmd`) and a README "Diagrams"
  section held to them.
- ADR 0033/0034/0035: eras/lineage extracted behind a registered boot
  gate as a loadable Ruby plugin, with optional Rust lineage.

### Changed

- README rewritten for adoption; the Quickstart-blocking bug it exposed,
  and a license gap, both fixed.
- Removed client-specific deploy artifacts (`embryonaut`,
  `lifeadelics*`) that had been tracked alongside the public example
  domains.

### Docs

- Reconciled `docs/future-features.md`'s "Bug audits" section against
  current `main` — every `H`-numbered audit finding is now marked with
  its real, live-verified status instead of a stale "still open as of
  2026-08-11" blanket claim. See that section for exactly what was and
  wasn't re-verified this pass.
- Fixed a tracking-doc row that wrongly claimed the fuzzer-adapter gap
  was fixed by an unrelated commit (`docs/audits/2026-08-26-issue-tracker-reconciliation-plan.md`) —
  found independently, alongside H1 above, while reconciling docs
  against code in both directions.

[Unreleased]: https://github.com/chrisyoung/hecks/compare/v0.3.0...HEAD
