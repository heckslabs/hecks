# i722 — warm dispatch drops adapter output (EventTrace doesn't carry it)

The warm serve path (resident daemon over its unix socket) returns an events
array that carries only `kind`, `verb`, `ok` per event — see
`rust/src/run_serve/mod.rs:130-136`. The `[claude_tool:<tool>] ok= exit= output=…`
adapter line is a bare `println!` (`rust/src/runtime/mod.rs:966`) that is never
recorded into the dispatch timeline at all — there is no `record_event` call for
the claude_tool / mcp adapter, and `EventTrace`
(`rust/src/runtime/dispatch_detail.rs:109`) has no `output` / `exit` / `error`
fields to hold it.

Consequence : a warm dispatch that fires a `:claude_tool` / `:mcp` adapter
surfaces only the echoed command state, never the adapter OUTPUT (tool stdout,
file content, grep matches).

## Why it's currently masked (and the trigger condition)

As of this session, `serve_child.mjs::warmDispatch` force-falls-back to the cold
one-shot path for **any `Tools::*` command** (alongside the existing
whitespace-arg fallback). The cold path scrapes the `[claude_tool:…]` log lines
via `parseEvents` and renders them under the new "Tool output" section, so
adapter output surfaces correctly there.

So the gap only bites a **non-`Tools::*` command that registers a `:claude_tool`
or `:mcp` adapter via `result_into`** and dispatches with all-no-whitespace args.
That shape is rare-to-nonexistent today, which is why the cold-path fix +
force-cold guard was enough to close the live problem.

## Fix direction (when it bites)

1. Extend `EventTrace` (`dispatch_detail.rs`) with `output: Option<String>`
   (and `exit: Option<i64>`, `error: Option<String>` for cold/warm render
   parity).
2. Record the claude_tool / mcp adapter into the timeline — replace the bare
   `println!` at `mod.rs:966` with a `storehouse_log` surface that both prints
   the line AND calls a `record_event`-style hook carrying output/exit/error.
3. Serialize the new fields in `run_serve/mod.rs:130-136`.
4. Then the warm-path force-cold guard for `Tools::*` in `serve_child.mjs` can be
   relaxed (warm becomes safe for adapter-bearing commands).

Filed while shipping the cold-path Tool-output surfacing fix (this session).
