# RESTART — standalone pizzeria on a projected binary (SQLite first, Ruby MySQL after)

> Fresh-head handoff. Prior session hit context limit mid-plan. The PLAN is
> `~/.claude/plans/piped-finding-rabin.md` — READ IT FIRST ; this card frames it.

## Where we are (all landed)

- **Ruby↔Rust in-process interop PROVEN** (magnus spike). `~/Projects/pizzeria`
  (committed `c0071ff`, not pushed) : a magnus cdylib loads Rust and calls
  `storehouse::embed::dispatch_once` in-process, gated. `ruby spike.rb` shows
  alice admits / mallory denies, bare==FQN, panic-safe, store persists. Details
  + toolchain (magnus 0.7.1, the `-undefined dynamic_lookup` link flag, the
  vendored-authz-context pattern) in memory `project_ruby_rust_interop.md`.
- **`storehouse::embed`** (one-shot dispatch/query entry, panic-safe, per-call
  Principal, HTTP result shape) merged to hecks main (PR #753). This is what the
  binding calls.
- Earlier tonight's arc all merged : authz platform (#744–748), FQN security fix
  (#750), async-verdict phantom fix (#751), causation view (#752), UI bearer
  (#749). Findings filed : `BUG-value-object-invariants-dropped.md` (foundational
  — VO invariants silently dropped, + type/required/reference gaps),
  `FOLLOWUPS-authz-arc-close.md`, `SECURITY-*`, `BUG-async-*`.

## The correction that triggered this restart (Chris, 2026-07-03)

The pizzeria app must be **STANDALONE — NO reference to the hecks project**. The
spike's ext crate path-deps `storehouse = { path = "…/hecks/rust" }` — REMOVE
that. The framework reaches the app as a **PROJECTED BINARY** : a compiled
artifact (the `storehouse` binary and/or the magnus `.bundle`, built WITH sqlite
registered) copied INTO the pizzeria folder. Rust source + build stay in hecks ;
only the OUTPUT lands in pizzeria. "It's good to create a copy here, but the app
just uses the projected binary."

## The open design question to resolve FIRST (fresh exploration)

**How is a standalone binary/`.bundle` projected?** The specializer's
embedded-bluebooks / per-domain binary emitters were RETIRED 2026-06-27 (only
the Ruby static target survives). So "project a binary" may have NO shipped
mechanism — it might need building. Investigate : is there a `storehouse`
subcommand or build path that emits a standalone artifact carrying a chosen
domain + chosen wired adapters (sqlite) with NO framework-source dep in the
consumer? If not, the projection step is itself the first deliverable (a build
script that compiles the ext with sqlite registered and drops the `.bundle` +
the `storehouse` binary into the app, decoupled from the app's own build).

## The goal once projection is settled

**Use the EXISTING SQLite (Rust) adapter in pizzeria** — NOT a new adapter.
SQLite is a wired adapter selected by `adapter :sqlite, db: "…"` in the
hecksagon (context-scoped), registered under token `"sqlite"`. The projected
artifact MUST compile in `storehouse_sqlite::register()` (the CLI binary already
does ; a magnus `.bundle` needs the `storehouse-sqlite` dep + a `register()`
call in `#[magnus::init]` — but built in hecks, projected out). Prove pizzas
persist to a real `.db` : `sqlite3 pizzeria/…/pizzas.db 'select * from pizza;'`
after a dispatch, via BOTH the CLI binary and the in-process ext. Full SQLite
template + seams (trait `PersistenceAdapter`, the registry, the parser `:sqlite`
arm, typed-column serialization, the refuse-on-bad-schema test) are in the plan
file's "What already exists" + "crux" sections.

## Then (Chris's "provide both")

Ruby MySQL adapter — same `PersistenceAdapter` contract via `mysql2`, called from
Rust (embedded VM = the magnus machinery in reverse, OR the out-of-process
adapter-host handler which ALREADY spawns any program : `run_host::exec`). Parser
already accepts `:mysql`. Payoff : Pizza on SQLite (Rust) beside an aggregate on
MySQL (Ruby), chosen per adapter.

## First moves for the fresh head

1. Read the plan file + `project_ruby_rust_interop.md`.
2. Resolve the projection mechanism (explore : does a standalone-artifact
   projection exist, or must it be built?). This is the gate.
3. Then wire SQLite (CLI path proves it with zero new code ; ext path needs the
   projected-with-sqlite `.bundle`).
4. Keep the pizzeria standalone — verify no `~/Projects/hecks` path-dep survives
   in the shipped app.
