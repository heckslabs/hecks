# PRD 02 — Run the fuzzer/property suite against real adapters, not just Memory

**Status:** Not started. Largest PRD in this set.

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
