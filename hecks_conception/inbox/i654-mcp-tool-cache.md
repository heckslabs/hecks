---
ref: i654
status: designed
category: framework-domain
title: MCP tool-cache — persistent hot-path roster + discoverable catalog
---

# i654 — MCP tool-cache (Layer 1 hot-path preload + Layer 2 discovery surface)

## Why

Every session, hundreds of tools are deferred behind `ToolSearch`. Two
distinct lived failure modes :

1. **Wasted round-trips.** Hot tools (`mcp__storehouse__storehouse__dispatch`,
   `Voice.Speak`, `FileTool.Edit`, `ShellTool.Bash`, `Gmail.get_thread`)
   are called dozens of times per session. Each one needs a ToolSearch
   round-trip before it can be invoked — overhead on every hot path.

2. **False blockers.** When the LLM guesses a tool name and ToolSearch
   doesn't match, the LLM concludes "the tool doesn't exist" and reports
   that as a blocker. Sometimes the tool DOES exist under a slightly
   different name. This was the 2026-05-19 Gmail-attachment incident.

The fix is two-layered.

## The two layers

### Layer 1 — Hot-path preload (via additionalContext injection)

Claude Code has no native "pre-load these tools" hook ; ToolSearch is the
only loader and it's pull-only. The cleanest substitute — which `tools
.bluebook` calls out via `MetaTool.ToolSearch` and which the existing
project `.claude/settings.json` already uses for wake-review and restart-
prompt surfaces — is **UserPromptSubmit `additionalContext` injection**.

`bin/update-tool-cache` :

  * walks every `~/.claude/projects/*/*.jsonl` modified in the last 14 days
  * tallies each `tool_use` block's `name`
  * renders the top-40 as a markdown catalog grouped by MCP server
  * writes `/tmp/tool_cache_latest.md` (the additionalContext surface)
  * writes `~/.claude/tool-cache.json` (the projected per-tool stats —
    the discovery surface reads from here)
  * dispatches `ToolCache::ToolStats.RecordCall` per top-N entry and
    `ToolCache::ToolCacheSnapshot.Compose` for the snapshot (bus events
    are the truth, JSON + markdown are projections)

A SessionStart hook fires `update-tool-cache` once per boot ; a sibling
UserPromptSubmit hook injects `/tmp/tool_cache_latest.md` as
`additionalContext` so the LLM sees the right tool names on the first
turn without any ToolSearch round-trip.

### Layer 2 — Discoverable catalog (`bin/storehouse-tools`)

```
$ bin/storehouse-tools                 # everything, grouped by server
$ bin/storehouse-tools storehouse      # just one server
$ bin/storehouse-tools --top 30        # top-N only
$ bin/storehouse-tools --json          # raw JSON for jq piping
```

Reads `~/.claude/tool-cache.json` and renders the full observed catalog.
This is the agent's enumerable discovery surface — instead of guessing
tool names, the agent (or human) lists what's there.

## Bluebook (`hecks_conception/aggregates/framework/tool_cache/`)

Two aggregates :

  * **`ToolStats`** — one record per observed tool name. Commands :
    `RecordCall(tool_name, seen_at, description)`. State : `tool_name`
    (id), `call_count`, `last_seen_at`, `last_description`.

  * **`ToolCacheSnapshot`** — one record per composed top-N roster.
    Commands : `Compose(snapshot_id, composed_at, tool_count, top_n,
    roster_markdown)`. The roster_markdown rides in the
    SnapshotComposed event payload only ; aggregate state stays small.

7/7 behaviors green via `storehouse behaviors`.

## Runtime substrate

| Piece                                | Lives at                                  |
|--------------------------------------|-------------------------------------------|
| Transcript walker (Ruby)             | `tooling/tool_cache/transcript_walker.rb` |
| Snapshot renderer (Ruby)             | `tooling/tool_cache/snapshot_writer.rb`   |
| Cache writer CLI                     | `bin/update-tool-cache`                   |
| Discovery surface CLI                | `bin/storehouse-tools`                    |
| Bluebook + behaviors                 | `hecks_conception/aggregates/framework/tool_cache/` |
| Projected stats (read by Layer 2)    | `~/.claude/tool-cache.json`               |
| Catalog surface (injected at boot)   | `/tmp/tool_cache_latest.md`               |

## Hook wiring (to add to project `.claude/settings.json`)

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "ruby /Users/christopheryoung/Projects/hecks/bin/update-tool-cache >/dev/null 2>&1 || true",
        "timeout": 15
      }]
    }],
    "UserPromptSubmit": [{
      "hooks": [{
        "type": "command",
        "command": "F=/tmp/tool_cache_latest.md; M=/tmp/.miette_last_tool_cache_seen; if [ -f \"$F\" ] && { [ ! -f \"$M\" ] || [ \"$F\" -nt \"$M\" ]; }; then jq -Rs '{hookSpecificOutput: {hookEventName: \"UserPromptSubmit\", additionalContext: (\"MCP tool catalog (top tools, verbatim names) :\\n\\n\" + .)}}' < \"$F\"; touch \"$M\"; fi; true",
        "timeout": 5
      }]
    }]
  }
}
```

This pattern mirrors the existing wake-review + restart-prompt injection
so the next agent maintaining the hook surface recognizes it immediately.

## Honest known gap

**Descriptions are absent on first observation.** Transcript `tool_use`
blocks carry only `name` + `input` — not the schema description. The
projected JSON has `description: null` until something fills it in.
Two ways to close the gap, both deferred :

  1. A description-fetch pass that calls `ToolSearch` (or
     `mcp__storehouse__storehouse__catalog`) for the top-N and stores
     the result back into the JSON.
  2. Have the SessionStart system-reminder (which lists all deferred
     tools without descriptions, but with names) feed the JSON's name
     index even before any call has been observed.

The catalog WORKS without descriptions — the verbatim names are the
primary value. Descriptions are the second-pass polish.

## How to evolve

* When new MCP servers appear, no schema change : the walker tallies
  whatever it sees. `bin/storehouse-tools <newserver>` works the
  moment one call has been observed.
* The 14-day age window in `TranscriptWalker.walk(days:)` is tunable
  ; bump higher for slow-cadence tools, lower to weight recency.
* The top-N (default 40) is a render-time knob ; the JSON keeps every
  observed tool so a `--top 200` view stays meaningful.
* If/when the Claude Code harness exposes a real pre-load hook, the
  bluebook stays the same ; only `bin/update-tool-cache`'s output
  channel changes (write to the pre-load registry instead of
  `/tmp/tool_cache_latest.md`).

## Acceptance — what's green

- [x] Bluebook validates (`storehouse validate` clean)
- [x] Behaviors green (7/7 passing)
- [x] Cache writer + library files under 200 LoC each
- [x] Inbox card filed
- [x] Discovery surface CLI written
- [x] Hook wiring documented (see above ; merge requires user to add
      to `.claude/settings.json`)

## What's deferred

- Adding the SessionStart + UserPromptSubmit hooks to live settings.json
  (requires user touch of `.claude/settings.json`)
- Description backfill pass (Layer-1 polish ; the names alone close the
  primary friction)
- A `storehouse query ToolCache::ToolCacheSnapshot.snake_case` materializer
  that returns the most recent snapshot — currently the JSON projection
  serves the discovery surface ; the proper bus-truth query lands when
  the runtime substrate writes snapshots back to .heki
