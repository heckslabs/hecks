# Impure-edge inventory — the Rust runtime core

## Context

You asked: now that we've established hecksagon adapters call out to binaries
(the LLM just made that trip in `a66c9dccd` — `BodyDream::Dream.imaged_by` →
event → `bin/adapter-host` runs an external handler off-core → verdict re-enters
via storehouse, exactly the pizzas `charged_by("Stripe")` → `stripe-handler`
pattern), where are all the OTHER impure edges still baked into the runtime?

This is the inventory. It is a reading, not a change request — nothing here is
proposed for tonight. The value is the **gap column**: for nearly every edge the
*bluebook side is already declared* (an adapter family + a behavior_kind), but
the *execution is still inline Rust inside the synchronous core*. LLM is the one
that has actually crossed.

**Scope.** In: `rust/src/runtime/` — the synchronous domain/dispatch core, which
the hexagon says must be pure. Out: `main.rs`, `run_*`, `specializer/*` —
surface-glue (Nirmanakaya), legitimately impure. Persistence (heki / sqlite /
memory repository) is in-scope but is the **blessed in-process edge** the hexagon
explicitly DI's inline — not a violation.

**The axis that keeps this honest.** "Off-core" ≠ "a subprocess exists." The test
is: *does the synchronous core block on the impure work?* `exec`/`shell`/`web`/
`mcp` all spawn subprocesses, but the core composes the call, blocks on it, and
folds the result inline — that is still an in-core impure edge, same category as
an inline HTTP call. Genuinely off-core = emit event → adapter-host runs handler
→ verdict re-enters via storehouse. By that axis **only LLM has crossed.**

---

## The three-column map

| family (declared) | behavior_kind (declared) | current execution | crossed off-core? |
|---|---|---|---|
| `claude_tool` | `invoke_claude_tool` | `claude_tool_dispatcher/` — file Read/Edit/Update, Glob, Grep ; shells out, blocks inline | ❌ in-core |
| `web_tool` | `perform_web_fetch` / `perform_web_search` | `web_tool_dispatcher.rs` — shells curl + DuckDuckGo, blocks inline | ❌ in-core |
| `mcp` | `invoke_mcp_tool` | `mcp_dispatcher/` — spawns stdio MCP server (node), blocks inline | ❌ in-core |
| `tts` | `render_text_to_audio` | `tts_dispatcher.rs` — **in-process blocking `reqwest` HTTP** to ElevenLabs | ❌❌ in-core (worst) |
| `sms` | (sms) | `sms_dispatcher.rs` — kernel-floor handler | ❌ in-core |
| `exec` | `perform_exec` | `exec_dispatcher.rs` — spawn leaf, now reached via generic `Primitive::Process.Spawn` (i629) | ◐ refactored toward, not arrived |
| (llm) | (llm family bind) | `adapter_llm.rs` + `bin/adapter-host` + handler binary | ✅ **crossed** (`a66c9dccd`) |
| `heki`/`sqlite`/`memory` | `back_aggregate_storage` | `repository.rs` / `heki.rs` / `sqlite_repository.rs` | — blessed in-process (not a violation) |
| `html`/`markdown` | `render_report` | report rendering | ❌ in-core (pure-ish, low risk) |

The shop/pizzas demo (`examples/adapter_host_demo/stripe-handler`) is the second
proof the off-core path works for a real third-party edge.

---

## Sharpest violations, named

1. **`tts_dispatcher.rs` and `llm_providers/ollama.rs`** use `reqwest` / `ureq` —
   **in-process blocking HTTP**, not even a subprocess. These are the most-in-core
   edges of all: the synchronous core literally waits on a socket. (LLM's *ollama*
   path still does this even though the *claude/dream* path crossed — the family is
   half-migrated.)
2. **`web_tool_dispatcher.rs`** — shells curl for an arbitrary HTTP GET, inline.
3. **`mcp_dispatcher/`** — spawns a node MCP server per call, inline.
4. **`claude_tool_dispatcher/`** — every file/grep/glob tool I use routes through a
   blocking in-core dispatcher.

All of these carry the identical `antibody-exempt` marker: *"kernel-floor handler
… retires when the framework-wide kernel-hook registry (i557) replaces hard-coded
handler tables."* i557 is the standing card that names this whole class.

---

## What `antibody-exempt` does NOT mean (honesty guard)

The 38-file marker list in `src/runtime/` is a **superset** of the impure edges.
Driven off the *syscall grep* (the real impurity), several exempt files are exempt
for OTHER reasons and are NOT impure edges:

- `command_dispatch.rs` — regenerated projection (codegen), not IO.
- `aggregate_state.rs`, `reaction.rs`, `pm_engine.rs`, `event_driving.rs`,
  `interpreter.rs` — kernel **interpreter**, the pure engine, not outbound IO.
- `driven_adapter_resolver.rs` — the engine that *runs* hecksagon adapters
  in-process; inherently Rust (it's the resolver, not an edge).

Counting markers would inflate the inventory. The real outbound-IO edges are the
dispatcher rows in the table above.

---

## Two classes that are NOT "should be a binary" (own section)

**Driving / inbound edges** (different shape — the hexagon's *driving* side, not an
outbound adapter):
- `server/` (`TcpListener` in `mod.rs`, `multi.rs`, `lib.rs`) — the HTTP server.
- `runtime/loop_driver.rs` + `clock.rs` — the clock/driver that reaches IN on a
  schedule. This is exactly what the new `aggregates/language/grammar/driving.bluebook`
  conceives (the Driver category). Inbound, not a binary-calling adapter.

**Non-determinism baked in** (ambient impurity — not an adapter at all, but worth
naming because it breaks reproducibility):
- `SystemTime` / `Instant::now` — `clock.rs`, `interpreter.rs`, `loop_driver.rs`,
  `storehouse_log.rs`, `repository.rs`, `heki.rs`.
- `rand` — `interpreter.rs`, `util.rs`.
- ambient `env::var` reads scattered across ~25 runtime files (config that should
  arrive via `.world`, not be read inline).

---

## The migration template (already proven, for reference)

Each in-core edge would cross the same way LLM did:
1. Bluebook: bind the aggregate to its family via the FQN-verb form
   (`Aggregate.verbed_by(...)`), emitting an event.
2. Handler binary: a small program that does the impure work, speaking only the
   storehouse door (stdout `k=v` per line → verdict attrs).
3. `bin/adapter-host` runs it off-core; the verdict re-enters as a command.
4. Retire the in-core dispatcher; drop its `antibody-exempt` marker.

i557 (kernel-hook registry) is the structural close for the whole class.

---

## This is a reading, not a work order

No edits proposed. If you want, the natural next step is to pick ONE edge (tts or
web_tool are the cleanest, ollama the highest-value since it half-finishes the LLM
family) and make it cross — but that's a separate, gated session, not this turn.
