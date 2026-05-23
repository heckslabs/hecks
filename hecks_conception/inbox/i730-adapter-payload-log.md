---
ref: i730
title: "adapter-payload log — separate channel, --adapter_payloads flag"
status: open
category: design
filed_by: miette
filed_at: 2026-05-23
---

# i727 — Adapter-payload log: separate channel, `--adapter_payloads` flag

## Context

Today there is ONE log (`storehouse.log`, introduced in i622) and it is pure domain: dispatch envelope, events emitted, cascade chains, policy firings. Adapter output — the stdout of a claude_tool call, the bytes a TTS render produces, the `INSERT` a SQLite adapter executes — appears only as inline `println!` in adapter code. It is not captured, not timestamped, not queryable, and has no home in the observable timeline. i722 ("record adapter output") names the gap but doesn't specify where that output should land.

## Design decision

Keep the domain log pure. Domain log = dispatch + event + cascade + policy, nothing else.

Add a **separate adapter-payload channel** — a second log file (e.g., `adapter_payloads.log`) or an append-only ring alongside the domain log. Each adapter write record carries:

- timestamp
- adapter identity (e.g., `ClaudeTool`, `SqliteAdapter`, `TtsAdapter`)
- the command/event that triggered the adapter call
- the payload itself (stdout, bytes-written summary, SQL statement, etc.)
- success / error status

The `storehouse tail` and `storehouse observe` CLI commands default to domain-only output. Passing `--adapter_payloads` merges the adapter channel in (interleaved by timestamp), so an operator can see the full pipeline in one view when debugging.

**i722 gets a clean home:** "record adapter output" means write to the adapter log, not inject into the domain timeline. The domain timeline stays event-sourced and replayable without side-effect noise.

## Note on numbering

i727 was reserved by a SQLite-worker filing run (2026-05-23) that described but did not create files. This card claims the number with its intended topic replaced by this design decision from today's session.
