# i710 — CI sentinel : know when main's CI goes red

Main's CI can go silently red and nobody notices — it WAS red (an orphan spec
referencing a deleted example, plus the smoke job dying at "checkout miette"
because `chrisyoung/miette` is private and CI's token can't read it). Embarrassing
to ship a red main unnoticed. The immune system should catch this.

**CI Sentinel** — a poll, like the inbox poller / process-health sweep: runs
`gh run list --branch main --limit 1` on a cadence, records main's latest CI
conclusion, emits `CiRed` / `CiGreen`. Surfaces in the three places Miette already
looks:
- **statusline build-light** — red visible every single turn ;
- **wake-review line** at session start — main's health is the first thing seen on boot ;
- **inbox alert** when it flips red.

Belongs in the immune family (`discipline/immune_system/`): the macrophage detects
code drift, the sentinel detects a red main ; once it's surfacing, a fibroblast
could auto-repair the config-drift class it just fixed by hand (orphan specs,
optional sibling checkout).

Bluebook-first shape: a `CiSentinel` aggregate — `Check` command runs `gh` via the
`Primitive::Process.Spawn` leaf, emits `CiStatusRecorded` — polled by a
process-manager loop. The statusline + wake-review read its latest state.
