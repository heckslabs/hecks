# i27 — Nursery viability metrics

Source: inbox `i27` + plan by Agent a31587a2 on 2026-04-22.

## ⚠ Adjustment needed before implementing

The original plan specified `nursery_scan.py` — **violates i37** (Python ban). Rewrite in Ruby or orchestrate via shell + `hecks-life heki` subcommands (PR #272 shipped). The viability logic is straightforward enough for either path.

## What it does

Per-domain tabulation of nursery health. 375+ bluebooks under `nursery/`. Seven fields per record:

| Field | Source |
|---|---|
| `domain` | directory name (relative path for nested) |
| `rust_boot_ok` | `hecks-life parse <bluebook>` exits 0 |
| `ruby_boot_ok` | `bin/hecks-behaviors --parse-only` exits 0 |
| `fixtures_present` | sibling `fixtures/*.fixtures` non-empty |
| `behaviors_present` | sibling `<name>.behaviors` exists |
| `behaviors_pass` | enum: pass_both / pass_rust_only / fail / n/a |
| `last_touched` | `git log -1 --format=%cI -- <path>` |

**Viability policy (v1, Rust-primary):**
```
viable = rust_boot_ok AND ruby_boot_ok AND behaviors_present 
         AND behaviors_pass ∈ {pass_both, pass_rust_only}
```

Ruby failures counted but not blocking until i1/i2 fully retired (they're closed via i24 but some residual may remain). Record `"viability_policy": "rust_primary"` in JSON output.

**KPIs**: viable_count, rust_green_count, ruby_green_count, has_fixtures_count, has_behaviors_count, stale_count (>30d), dead_count.

## Nursery aggregate

Add inside `aggregates/conception.bluebook` (Conception already owns the nursery vocabulary):

```
aggregate "Nursery" do
  attribute :domain_name, String
  attribute :path, String
  attribute :last_checked_at, String
  attribute :rust_boot_ok, String
  attribute :ruby_boot_ok, String
  attribute :behaviors_pass, String
  attribute :last_touched, String
  attribute :consecutive_fail_count, Integer

  lifecycle :status, default: "gestating" do
    transition "RecordBirth"    => "born",     from: "gestating"
    transition "RecordViable"   => "viable",   from: "born"
    transition "RecordViable"   => "viable",   from: "flagged"
    transition "FlagRegression" => "flagged",  from: "viable"
    transition "Retire"         => "retired",  from: "viable"
    transition "Retire"         => "retired",  from: "flagged"
  end

  # Commands: RecordBirth, RecordViable, FlagRegression, Retire
end
```

Cross-wire via policy: `on "IndexedInNursery" → trigger "RecordBirth"` in Conception.

**Anti-flap rule**: require 2 consecutive failing runs before `FlagRegression` fires. Track `consecutive_fail_count` on the heki record.

## Caching

SHA-keyed cache in `information/nursery_stats.cache.json` keyed by `(path, git_sha_of_file)`. Subsequent runs only re-check changed files.

- Cold: ~5min (all 375 domains, 2 boot checks each, parallelized `-P 8`)
- Warm: ~25s

## Weekly KPI

Cron-style: Sunday 00:00 UTC, `weekly_viability.sh` runs `nursery stats --json`, appends to `information/kpi_viability.heki` with `{week_of, viable_count, total, rust_green, ruby_green}`. Sparkline in text report reads last 12 weeks.

## Commit sequence (6)

1. `feat(nursery): scanner + shell wrapper (Ruby, no Python)` — stats script + wrapper, emits JSON + colored text
2. `feat(nursery): wire as hecks-life nursery subcommand`
3. `feat(conception): Nursery aggregate with lifecycle + birth policy`
4. `feat(nursery): lifecycle dispatch from scanner (RecordViable/FlagRegression with anti-flap)`
5. `feat(nursery): weekly KPI + sparkline + smoke test`
6. `docs: CLAUDE.md + close inbox i27`

## LoC estimate

~650 total (down from the Python version, since shell + hecks-life subcommands are denser).

## Key files

- NEW: `hecks_conception/bin/nursery_stats.sh` (shell wrapper — swap the Python scanner for a Ruby one or use `hecks-life heki` subcommands directly)
- MODIFY: `hecks_conception/aggregates/conception.bluebook` — add Nursery aggregate
- NEW: Rust `hecks-life nursery` subcommand glue in `hecks_life/src/main.rs`
- NEW: `tests/nursery_stats_smoke.sh` with fixture nursery

## Risks

- **Python ban violation** — rewrite in Ruby (addressed above)
- Ruby runner path drift (`bin/hecks-behaviors`) — feature-detect once at scanner start
- Nested bluebook namespacing (`alans_engine_additive_business/hecks/*.bluebook`) — key by relative path
- Lifecycle churn from boot flakiness (addressed by anti-flap rule)
