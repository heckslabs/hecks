# `.test.world` — memory is the test floor, real store is a named override

**Status:** SPEC (design locked with Chris 2026-06-27). Bluebook-first build is
the next effort, its own branch.

## Problem

Chris's mental model is "tests are always in memory." It only half-holds:

- The Rust behaviors + unit suite IS memory — it boots through
  `Runtime::boot_in_memory()` -> `force_memory_repositories()`, no disk.
- The shell smoke tests under `hecks_conception/tests/*.sh` are NOT. They drive
  the real `storehouse` CLI as separate OS processes and let persistence
  resolve from a `.world` they write (`dir :default` -> disk in a tmpdir).

They touch disk by construction: they assert across a process boundary (e.g.
`pulse_organs_smoke` runs `run-loop` as a daemon process, kills it, then runs
`heki count` as a SEPARATE process). In-process Memory is a HashMap that dies
with the process — process B would read an empty store. So these few are
genuinely integration/persistence tests; they cannot become Memory without
being rewritten as single-process tests.

The real defect: the CLI boot default is DISK
(`boot_with_data_dir` -> Heki@data_dir), so persistence is opt-OUT for tests
instead of opt-IN. We want the inverse.

## Decision (locked)

1. **Memory is the FLOOR.** When no world opts an aggregate into a backend ->
   `Backend::Memory`. This flips the bare-conception default from Heki@data_dir
   to Memory. Most tests need no file at all.
2. **`*.world` = production wiring** (disk via `dir :default`). Unchanged.
3. **`*.test.world` = test-scoped override.** A separate artifact (same world
   parser) where a persistence test names an explicit isolated real store
   (`heki do; dir "$TMP/store" end`). It WINS over `*.world` when both are
   present. The explicit `dir` does double duty — it configures the real store
   AND marks the test as a persistence test.
4. **Detection rides FILES, never env.** No `HECKS_TEST=1` flag. The i728
   env-var cutover postmortem (inbox) is exactly why `HECKS_INFO` was killed —
   an env switch lets the writer and reader resolve differently (split-brain).
   The world stays the single authority; `.test.world` is just a world.
5. **NO `test do ... end` block in the deployment world.** Rejected: the world
   is production VALUES; a test sub-mode doesn't belong in the shipped artifact,
   one world can't vary per-test, and it would duplicate `persisted_by`
   (`"Memory"` / `"Heki"`) — a second way to say one fact, which the macrophage
   exists to prevent.

## Blast radius (Chris confirmed acceptable)

Memory-as-floor only changes conceptions that have NO world at all. The live
body is safe — every organ already ships a `.world`. CLI usage against a
world-less conception becomes ephemeral (was disk); that's the intended
principle ("runtime defaults to memory").

## Implementation (bluebook-first)

1. **World grammar** — recognise `<name>.test.world` as a test-scoped world;
   encode the memory-floor rule.
2. **Persistence resolution** (`rust/src/runtime/persistence_resolution.rs`,
   `rust/src/heki.rs` world discovery) —
   - default `Backend::Memory` when no binding/world resolves a backend;
   - `.test.world` takes precedence over `.world`;
   - EXCLUDE `*.test.world` from the PRODUCTION `.world` glob. NOTE the trap:
     `foo.test.world` ends in `.world`, so the existing extension filter in
     `resolve_default_dir` / `resolve_realm_dir` would pick it up in prod.
     The discovery must skip `*.test.world` unless test-resolving.
3. **Wire the persistence smoke tests** — replace the `dir :default` world each
   writes with a `*.test.world` carrying an explicit isolated `dir "$TMP/..."`:
   consolidate, pulse_organs, pulse_fanout, body_cycles, status_golden,
   statusline_regression, interpret_dream, dream_content. (All 8 are
   multi-process, so all 8 stay on disk — just explicit + named now.)
4. **Verify** — smoke tests still pass against the explicit store; a world-less
   single-process test round-trips in memory only.

## Why this is the right shape

The backend is already a first-class declarative concept (`persisted_by`).
`.test.world` reuses it; it adds no vocabulary, keeps test config out of the
shipped world, makes memory the safe default, and makes a real store an
explicit, named exception — "wire specific tests to a different source."
