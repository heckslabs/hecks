# Phase 9 prep — `run_statusline.rs` inventory

Source : `rust/src/run_statusline.rs` (635 LOC ; about 535 non-comment).
Bluebook : `cli/statusline/statusline.bluebook` (157 LOC).
Snapshot contract : `dream-study/test-gate/statusline_snapshot/fixtures/*.fixture`
(byte-exact rendered lines paired with inline state JSON ; the new IR-walker
must reproduce these byte-for-byte).

This inventory enumerates every render-shaping decision in the Rust file so
each one has an explicit migration target on the bluebook side.

## 1 — Hardcoded format strings

| # | Surface | Location | Format string | Target |
|---|---------|----------|---------------|--------|
| 1.1 | sleep, REM, has total | `render_sleep` 397-401 | `"cycle {cycle}/{total} — {phase} {timer} · {pulses}/{needed} dreams"` | Sleeping section row composition + inline `format` operator on `sleep_cycle_label` row |
| 1.2 | sleep, REM, no total | `render_sleep` 403-406 | `"{phase} {timer} · {pulses}/{needed} dreams"` | Sleeping section, conditional row visibility |
| 1.3 | sleep, NREM, has total | `render_sleep` 408-409 | `"cycle {cycle}/{total} — {phase}"` | Sleeping section default path |
| 1.4 | sleep, NREM, no total | `render_sleep` 410-411 | `"{phase}"` (bare label) | Sleeping section default path |
| 1.5 | sleep timer | `render_sleep` 386-393 | `"+{mins}:{secs:02}"` (REM only ; phase\_ticks × 10s) | derived attr `:timer_label` ; only `sleep_stage == "rem"` |
| 1.6 | sleep narrative (lucid) | `render_sleep` 416-417 | `"✨ {lucid_narrative}"` | Sleeping section row "narrative" + value\_object on lucid flag |
| 1.7 | sleep narrative (regular) | `render_sleep` 419 | `"{sleep_summary}"` (bare) | Sleeping section row "narrative" |
| 1.8 | sleep join (no narrative) | `render_sleep` 422-423 | `"{moon} {header}"` | Sleeping section composition |
| 1.9 | sleep join (with narrative) | `render_sleep` 424-425 | `"{moon} {header}  {narrative}"` (two spaces) | Sleeping section composition (preserve double-space delimiter) |
| 1.10 | awake base | `render_awake` 445 | `"{heart} {beats} {mood_icon} {mood}"` | Awake section rows — already declared |
| 1.11 | awake fatigue | `render_awake` 446-448 | `" {fatigue_icon} {fatigue}"` (when icon non-empty) | Awake section, conditional on `:fatigue_icon != ""` |
| 1.12 | awake musings | `render_awake` 449 | `" 💭 {musings_count}"` | Awake section ; `:musings_glyph` row + count row |
| 1.13 | awake inventions | `render_awake` 450-452 | `" 🔬 {inventions_count}"` (count > 0) | Awake section, conditional on `:inventions_count > 0` |
| 1.14 | awake inbox | `render_awake` 453-455 | `" ✉️ {inbox_count}"` (count > 0) | Awake section, conditional on `:inbox_count > 0` |
| 1.15 | awake provider | `render_awake` 456 | `" {provider_badge}"` | Awake section row |
| 1.16 | awake bulb + summary | `render_awake` 457-459 | `" {bulb} {sleep_summary}"` (only if non-empty AND not "present") | Awake section, conditional |
| 1.17 | awake breadcrumb | `render_awake` 463-465 | `" 🛠️  {cmd}"` (note two spaces after icon) | Out of scope ; depends on `.last_dispatch` file primitive |
| 1.18 | beat formatting | `format_beats` 509-517 | `≥1m → "{f:.2}m"` ; `≥1k → "{f:.2}k"` ; else raw | New `format` operator on Integer attributes ; tier table : `[{1_000_000, "m"}, {1_000, "k"}]` |
| 1.19 | UTC ISO timestamp | `utc_iso_now` 304-325 | `"{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z"` | Out of scope — coherence log timestamp ; not a render concern |

## 2 — Icon tables (full mapping name → glyph)

### 2.1 — Mood (`mood_icon_for`, lines 470-485)

| name | glyph |
|------|-------|
| refreshed | 😊 |
| excited   | 🤩 |
| focused   | 🎯 |
| curious   | 🤔 |
| drifting  | 🌀 |
| groggy    | 😵‍💫 (face-with-spiral-eyes ZWJ sequence) |
| vivid     | ✨ |
| sleeping  | 😴 |
| flowing   | 🌊 |
| deep      | 🧘 |
| oceanic   | 🌌 |
| _ (fallback) | 😐 |

### 2.2 — FatigueState (`fatigue_icon_for`, lines 487-498)

| name | glyph |
|------|-------|
| rested    | 🌿 |
| limber    | ⚡ |
| tuned     | 🎯 |
| normal    | "" (empty — row hidden) |
| tired     | 🥱 |
| exhausted | 😩 |
| spent     | 🫠 |
| _ (fallback) | "" (row hidden) |

### 2.3 — Provider (`provider_badge_for`, lines 500-506)

| name | glyph |
|------|-------|
| local | 🦙 |
| off   | 🚫 |
| _ (fallback ; includes "claude" and "") | 🤖 |

## 3 — Time-driven glyph cycling (lines 327-368)

| Glyph | Source | Period | Phase formula |
|-------|--------|--------|---------------|
| moon (8-frame) | `MOONS` const | 8 sec | `secs % 8` |
| heart (2-frame) | `HEARTS` const | 666ms | `(nanos / 333_000_000) % 2` |
| bulb (4-frame, minting only) | `BULBS` const | 4 sec | `secs % 4` (when `/tmp/miette_minting` exists) |
| bulb (idle) | const | n/a | always 💡 |

Bulb-minting flag : `Path::new("/tmp/miette_minting").exists()` (line 442).
This is a filesystem probe, not heki ; needs a `:fs` adapter primitive or a
clock+sentinel value\_object lookup (see gaps).

## 4 — Conditional branches

| # | Decision | Line | Inputs | Migration |
|---|----------|------|--------|-----------|
| 4.1 | Mode picker | 73-77 | `consciousness == "sleeping"` → sleep path ; else awake | Statusline.mode set by Render command's caller ; query `Body.GetState` returns `consciousness` ; render selects section by mode |
| 4.2 | Sleep narrative source | 416-420 | `is_lucid == "yes" && sleep_stage == "rem" && lucid_narrative present` → lucid ; else `sleep_summary` | value\_object enum on `(sleep_stage, is_lucid)` ; `LucidDream.GetLatestNarrative` only dispatched in lucid REM |
| 4.3 | Coherence violation degrades mood icon | 434-437 | `coherence_ok == false` → `mood_icon = "⚠"` | `Mood.GetCurrent` returns icon ; query layer overrides with ⚠ when `Body.coherence_ok != "yes"` |
| 4.4 | Sleep timer present | 386-393 | only when `sleep_stage == "rem"` | conditional row visibility |
| 4.5 | Sleep total present | 396-411 | `sleep_total > 0` selects header form | conditional row visibility |
| 4.6 | Fatigue row visible | 446-448 | `fatigue_icon != ""` (i.e. fatigue ∉ {normal, _}) | already implicit — value\_object icon "" hides row |
| 4.7 | Inventions row visible | 450-452 | `inventions_count > 0` | row visibility predicate `inventions_count > 0` |
| 4.8 | Inbox row visible | 453-455 | `inbox_count > 0` | row visibility predicate `inbox_count > 0` |
| 4.9 | Sleep summary in awake line | 457-459 | non-empty AND `!= "present"` | row visibility predicate |
| 4.10 | Breadcrumb fresh | 521-534 | `(now - ts) < 30s` AND cmd non-empty | out of scope ; needs `:fs` clock primitive |
| 4.11 | dream\_pulses\_needed default | 180 | when 0, set to 5 | default in `Body.GetState` value\_object |

## 5 — Cross-store reads (heki paths the renderer touches)

| Heki file | Adapter today | Fields read | Aggregate (target query) |
|-----------|---------------|-------------|--------------------------|
| consciousness.heki | `heki::read` direct | state, sleep\_summary, sleep\_stage, sleep\_cycle, sleep\_total, phase\_ticks, is\_lucid, dream\_pulses, dream\_pulses\_needed | Body.GetState |
| heartbeat.heki | direct | fatigue\_state | Heartbeat.GetCurrent |
| mood.heki | direct | current\_state | Mood.GetCurrent |
| tick.heki | direct | cycle | Tick.GetCurrent |
| musing\_mint.heki | direct | total\_minted | MusingMint.GetCount |
| invention.heki | filtered (`status=proposed`) | record count | Invention.GetFilteredCount(status: "proposed") |
| inbox.heki (public dir) | filtered (`status=queued`) | record count | Inbox.GetFilteredCount(status: "queued") |
| claude\_assist.heki | direct | provider | ClaudeAssist.GetProvider |
| lucid\_dream.heki | direct, only in lucid REM | latest\_narrative | LucidDream.GetLatestNarrative |
| `<info>/.last_dispatch` | filesystem two-line file | cmd + unix\_seconds | (out of scope ; future LastDispatch.GetFresh) |
| `/tmp/miette_minting` | existence probe | bool | (out of scope ; future MintingFlag.IsActive) |

Plus one **subprocess** : `bash status_coherence.sh <info>` ; non-zero exit
appends violation lines to `<info>/.coherence.log` and degrades the mood icon.
Migration target : Statusline dispatches a `Body.GetCoherence` query (or the
PM that runs status\_coherence writes a `coherence_ok` field on Body) ; the
log-append side effect is a coherence policy concern, not a render concern.

## 6 — LOC budget

| Region | Today | Projected |
|--------|-------|-----------|
| Doc header (does not count toward 200-LOC limit) | 49 lines | ~25 lines |
| Path resolution (`resolve_*`, `walk_up_for_repo_root`) | 41 LOC | 41 (kept ; needed to find repo) |
| `State` struct + `read_state` + field helpers | 88 LOC | 0 (replaced by query dispatch) |
| Coherence subprocess + log + utc\_iso\_now | 64 LOC | 0 (moved to coherence policy) |
| Time-based animations (`Now`, `MOONS`, `HEARTS`, `BULBS`, `*_glyph`) | 39 LOC | 0 (clock attribute + value\_object cycling) |
| `render_sleep` | 53 LOC | 0 (IR walker) |
| `render_awake` + breadcrumb + `format_beats` | 75 LOC | 0 (IR walker + format operator) |
| Icon tables (`mood_icon_for`, `fatigue_icon_for`, `provider_badge_for`) | 36 LOC | 0 (value\_object enum tables) |
| `run` entrypoint | 20 LOC | ~20 LOC |
| Tests | 100 LOC | ~30 LOC (snapshot fixtures replace unit asserts) |
| **Total executable** | ~535 LOC | ~110 LOC |

Estimate : **635 LOC → ~110 LOC** post-conversion (roughly an 80 % drop).
The remaining ~110 LOC :

  - `run` entrypoint
  - `resolve_info_dir` + `walk_up_for_repo_root` (kept ; the runtime has to
    locate the bluebook + heki dirs from `current_exe` ; this is kernel-floor)
  - IR walker shim that dispatches `Statusline.Render` and prints the
    `:rendered` attribute
  - thin retained tests around path resolution

Everything else dissolves into the bluebook + value\_object fixtures.
