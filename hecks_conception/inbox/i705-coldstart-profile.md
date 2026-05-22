# i705 — storehouse cold-start profile (where the ~7s goes)

**Verdict: NO, parsing is NOT ~70%. Parsing all .bluebook files is ~0.4%.**
The ~7s tax is **eager per-aggregate .heki hydration at boot** — ~78%.
The "~70% is parsing" assumption was wrong by ~175x.

## Method

- Worktree `profile-coldstart` off main, own `target/`, release build.
- Lightweight `Instant` phase timers at every cold-boot boundary in
  `dispatch_hecksagon` (main.rs) + sub-phase timers inside
  `Runtime::boot_with_data_dir` (runtime/mod.rs). Instrumentation lives
  ONLY on the throwaway branch — never merged.
- One cold dispatch = one fresh process:
  `storehouse <root>/aggregates Tools::ShellTool.Bash shell_command='echo x'`
- Ran 3x. All three runs cluster tightly; table uses the median.
  (Run 1 vs 2/3 shows a small page-cache warmup only on the ~20ms parse
  phase — irrelevant to the dominant phase.)

## Per-phase breakdown (median of 3 cold runs)

| Phase | ms | % of real |
|---|---:|---:|
| process-start -> dispatch_hecksagon | ~0 | 0% |
| find_world_heki_dir | ~0 | 0% |
| load_combined_domain (319 .bluebook files) | ~19 | 0.4% |
| &nbsp;&nbsp;-- discovery (collect_bluebooks + sibling/bucket walks + sort) | ~4 | |
| &nbsp;&nbsp;-- **parse + merge (319 files)** | **~14** | **~0.3%** |
| load_all_hecksagons | ~6 | 0.1% |
| **Runtime::boot_with_hecksagons** | **~4250** | **~78%** |
| &nbsp;&nbsp;-- **Repository-creation loop (458 repos x ~9ms eager load_persisted)** | **~4250** | |
| &nbsp;&nbsp;-- policy_engine register (424 policies) | 0 | |
| &nbsp;&nbsp;-- pm_engine.load_persisted | 0 | |
| &nbsp;&nbsp;-- projections build | 0 | |
| &nbsp;&nbsp;-- FrameworkRegistry::build_from_dir (/nonexistent) | 0 | |
| register_llm_providers | ~4 | 0.1% |
| rt.dispatch (the ACTUAL command exec) | ~279 | ~5% |
| post-dispatch teardown (Runtime drop of 458 repos + stdio flush) | ~900 | ~17% |
| **TOTAL (real)** | **~5300-5500** | 100% |

## Which phase dominates

**`Runtime::boot_with_hecksagons` -> the repository-creation loop.** 458
aggregates, each `Repository::new_with_context(...)` eagerly calls
`repo.load_persisted()` in the constructor (repository.rs:89). For a
context-bearing aggregate, `load_persisted` does TWO `heki::read(path)`
calls (the migration probe at :136 + the real read at :147), plus a
`path_for` + `exists()` stat + an mtime stat. That is ~900+ filesystem
touches at boot. ~9.3ms x 458 = ~4.25s.

A single-shot `Tools::ShellTool.Bash` dispatch only needs ONE repo
(ShellTool). The other 457 eager loads are pure waste. The remaining
~900ms teardown is the mirror image: dropping those 458 Repositories +
their state HashMaps at process exit.

Parsing 319 .bluebook files into IR is ~14ms total. It is a rounding error.

## Is parsing really ~70%?

**No.** Parse+merge of all 319 .bluebook files is ~14ms = ~0.3% of the
~5.3s real time. Discovery (the recursive walk) adds ~4ms. Combined,
the "parse 162/319 .bluebook files" frame accounts for under 0.5% of
cold start. The parser is not a cold-start target.

## Recommended attack order

1. **Lazy repository hydration (recovers ~4.2s).** Defer
   `load_persisted` out of `Repository::new_with_context`; load on first
   access, or construct only the repo(s) the dispatch actually touches.
   For single-shot dispatch the other 457 repos never need to load.
   This alone takes ~7s -> ~1.2s. Highest leverage by far.
2. **Post-dispatch teardown (~900ms, ~17%).** Largely the 458
   Repository drops; likely shrinks naturally once #1 stops constructing
   them. Re-profile after #1 before investing here.
3. **rt.dispatch exec (~279ms, ~5%).** Only worth touching after #1+#2.
4. **Do NOT touch the parser.** ~0.4%. No cold-start payoff.

## Files implicating the root cause

- `rust/src/runtime/repository.rs:89` — `new_with_context` calls
  `load_persisted()` in the constructor.
- `rust/src/runtime/repository.rs:126-180` — `load_persisted`: double
  `heki::read` (migration probe + real read) + stats per aggregate.
- `rust/src/runtime/mod.rs:175-191` — `boot_with_data_dir`: the
  per-aggregate `Repository::new_with_context` loop (458 iterations).

_Profiled via worktree `profile-coldstart` (instrumentation not merged)._
