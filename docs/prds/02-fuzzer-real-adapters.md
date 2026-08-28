# PRD 02 — Run the fuzzer/property suite against real adapters, not just Memory

**Status:** Done for Sqlite and Postgres (2026-08-27). Postgres was
initially scoped out of this PRD's first round (see the original "What
shipped" below for why) and shipped as the follow-up round that section
called for, in a parallel branch merged the same day — `IsolatedBoot`
gained an actual settings-injection path for Postgres (a real `.world`
written per boot, a shared `hecks_fuzz` database/schema dropped and
recreated before every ephemeral boot, plus a `GC.start` fix for a real
`max_connections` exhaustion bug hit live). PostgresEra specifically
remains out of scope — nothing here touches era/lineage machinery.

## The problem

`lib/hecks/fuzzing/isolated_boot.rb` copies a domain to a tmpdir, wipes
`data/`, and rewrites **every** persistence binding to Memory before boot —
unconditionally, for every fuzz run, every property check, every replay.
That means the entire property-testing arc this session just built
(`lifecycle_guard_and_given_violations_are_refused`,
`mutations_match_recompute`, `stored_records_satisfy_declared_invariants`,
`dispatch_binding_fidelity`, all fifteen properties in
`lib/hecks/fuzzing/properties.rb`) has never once run against Sqlite,
Postgres, or Heki. Every one of those checks could be silently
Memory-adapter-specific and nothing today would know.

`spec/adapters/query_agreement_spec.rb` already proves this class of gap is
real: comparing Memory/Sqlite/Postgres/D1 on **queries alone** found four
shipped bugs (`ne:` with an empty string, array `in:`, `ne:` against a null
field, `in` on a numeric field — each invisible to a self-consistent
single-adapter spec). Nothing analogous exists for commands/mutations.

## Approach

1. Give `IsolatedBoot` a real adapter mode — instead of unconditionally
   rewriting every `persisted_by(...)` to `"Memory"`, accept a target
   adapter (`"Sqlite"` at minimum; `"Postgres"`/`"PostgresEra"` behind the
   same `io: true`-style local-skip convention the rest of the suite
   already uses for anything needing a real database) and rewrite bindings
   to *that* instead.
2. `SequenceGenerator`/`Replay` themselves should need no change — they
   already boot whatever `IsolatedBoot` hands back; the adapter swap should
   be invisible above that layer.
3. Wire a subset of the standard battery (`spec/fuzzing/properties_spec.rb`)
   to run twice — once against Memory (as today, fast, always-on locally)
   and once against Sqlite (still fast, no external service needed,
   suitable for the everyday local loop). Postgres gets the same `io: true`
   treatment every other real-database spec already has — excluded
   locally, included in CI and pre-push, per the pattern this session
   already extended for `spec/fuzzing` itself
   (`.githooks/post-commit`/`pre-push`, `fuzzing: true`).
4. Expect findings, not just green — this is explicitly a bug hunt, not a
   coverage-completeness exercise. Budget time to investigate and fix
   whatever the first real Memory-vs-Sqlite divergence turns out to be,
   the same way the fuzzer property arc budgeted for the entity-identity
   collision it found along the way.

## Acceptance criteria

- [ ] `IsolatedBoot` (or a sibling) can boot a fuzzed/replayed domain against
      Sqlite, not only Memory, with no change required in
      `SequenceGenerator`/`Replay`/`Properties`.
- [ ] The standard battery runs against both Memory and Sqlite locally;
      Postgres/PostgresEra run the same way under `io: true`.
- [ ] Any real divergence found gets its own bug-fix commit, not silently
      special-cased away in the harness.
- [ ] `bundle exec rspec` (local, no `io`) still finishes in a reasonable
      multiple of today's time — doubling the property battery's own
      wall-clock is expected; if Sqlite boot overhead makes it materially
      worse than that, that's its own finding worth surfacing, not
      absorbing silently.

## Non-goals

- D1/Cloudflare-adapter fuzzing — `query_agreement_spec.rb`'s own D1
  coverage is conditional on real Cloudflare env vars; this PRD doesn't
  need to force that dependency onto the property suite too.
- Fuzzing concurrent access to a real adapter (that's PRD 01's territory,
  and a real database's own locking semantics are a different question
  from a single fuzzed sequence's correctness against it).
- Rewriting `IsolatedBoot`'s tmpdir-copy mechanism itself — that's a
  separate, already-discussed idea (in-memory domain loading, no real disk
  I/O at all) with its own tradeoffs; this PRD only needs it to target a
  different adapter, not to stop copying files.

## What shipped

`IsolatedBoot.call(domain_path, adapter: :memory)` — `:memory` (unchanged,
every existing caller keeps today's exact behavior with no code change) or
`:sqlite` (rewrites `persisted_by(...)` to `"SqlitePersistence"` — the
actual registered adapter name; `Sqlite` is the bare class,
`SqlitePersistence` the port binding — instead of deleting it). Needs
**zero** `.world` settings either way: `Sqlite#resolve_path` already
defaults an unbound `database` setting to `data/<table>.db` under `root:`,
and `Hecks.boot(copy)` passes this ephemeral copy's own directory as
`root:` — a fresh, empty `data/` per run, same zero-history guarantee
Memory gets from having no `.world` at all, just backed by a real SQLite
file. `Replay.call` grew the same `adapter:` keyword (default `:memory`,
so every existing call site is unchanged); `SequenceGenerator` itself was
NOT touched, exactly as scoped — sequence GENERATION stays Memory-only
always (its job is discovering a valid step list, not observing storage
behavior; only the REPLAY that checks properties needs the real adapter).

`spec/fuzzing/properties_spec.rb` gained a second "standard battery"
describe block, same domains (pizzas, banking — `entity_list_mutations`
excluded, it ships with no `.hecksagon` at all, nothing for the rebind to
touch), same properties, run a second time against `adapter: :sqlite`.
Lives under `spec/fuzzing/`, so it's `fuzzing: true`-tagged like every
sibling spec there — zero added time to the default local `bundle exec
rspec` loop (acceptance criterion 4), unconditional in CI, on demand
locally via `--tag fuzzing`, exactly the existing convention.

**Findings**: green on the spec's own 5-seed sample, AND on a much wider
direct sweep run outside the spec suite (60 seeds × pizzas/banking, plus
30 × entity_mutations, × both adapters — 150 combinations, zero property
failures, zero crashes) — including with PRD 05's widened numeric
edge-case tables (Bignum/NaN/Infinity/-0.0) folded in at the same time.
No Memory-vs-Sqlite query/mutation divergence found, unlike
`query_agreement_spec.rb`'s own four — this corpus's real query/mutation
shapes evidently don't hit whatever those four needed, at the volume
tested here.

**Postgres was initially NOT added** in this PRD's first round, for the
reasons the paragraph above this one used to explain: Memory and Sqlite
both need zero `.world` settings, so the simple regex-rewrite-then-
delete-`.world` mechanism had nowhere safe to source a real connection
string from.

**Shipped as the follow-up round, same day (2026-08-27):**
`IsolatedBoot#rebind_to_postgres!` writes a real, fresh `.world` per
`.hecksagon` file (one per directory a `.hecksagon` actually lives in —
`Folder#load_domain` globs `*.world` non-recursively, so it has to match
that exactly or the world silently never loads; cost a debugging loop the
first time), pointing every domain at a shared `hecks_fuzz`
database/schema that's dropped and recreated before every ephemeral boot
(`ensure_fuzz_schema!`) — safe because `bin/fuzz` drives every boot
sequentially, never concurrently. A real bug surfaced live in the process:
`Adapters::Postgres` never explicitly closes a connection, and a tight
fuzzing loop (dozens to hundreds of ephemeral boots per run) hits
Postgres's own `max_connections` in about a dozen boots without help;
fixed with an explicit `GC.start` right before each boot's connections
open, reclaiming the previous boot's now-unreferenced ones.

A second real bug, unrelated to the fuzz harness itself, blocked even
booting: `SchemaBuilder#index_field!` didn't recognize the DSL's own
reference-hop convention (`"owner/field"`) and tried to index it as a
plain identifier, producing invalid SQL — any Postgres-bound domain with
a hop-derived field (banking's `projects :customer_status, from:
:"customer.status"`) failed to boot on real Postgres at all, previously
unreachable because banking had never run on real Postgres before this
PRD's real-adapter mode existed to try it. Fixed with the same
never-indexed-is-always-safe skip the DSL layer already applies
elsewhere.

Verified against `examples/banking`: `--adapter postgres --seeds 15
--steps 25` → 40.7s, 15/15 clean. Postgres is real work per dispatch, so
this mode is meant to run with smaller seed/step counts than Memory/
Sqlite's default sweep, not as a like-for-like swap.

**Still open, flagged rather than silently assumed solved:** the fix
above unblocks *booting* a hop-field domain on Postgres; whether the
query compiler can actually *execute* a hop-path `where`/`order_by`
against Postgres/Sqlite is untested and likely has the same class of
gap. **PostgresEra remains fully out of scope** — nothing here touches
era/lineage machinery; a fuzzed sequence against `PostgresEra` would need
its own PRD.
