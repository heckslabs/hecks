# EmailTool — Gmail Invocations as First-Class Dispatches

`EmailTool` (defined in
`hecks_conception/aggregates/framework/tools/tools.bluebook`) lifts each
Gmail tool call into a domain command. Where Miette's Gmail calls used
to be opaque MCP invocations — harness calls `mcp__claude_ai_Gmail__*`,
returns a string, runtime sees nothing — every `SearchThreads`,
`GetThread`, `CreateDraft`, or `ListDrafts` is now a dispatch on the bus
that emits a matching event.

This closes the bypass Chris named on 2026-05-14 :

> "ALL of your tool calls should go through the StoreHouse."

The four commands ship as the contract ; the `:mcp` adapter bindings
(see `tools.hecksagon`) declare which MCP tool a given EmailTool
command flows to. End-to-end execution lights up when the matching
runtime gaps close (see "Runtime status" below).

## The four commands

| Command         | Attributes                                       | Emits             | MCP tool                                  |
|-----------------|--------------------------------------------------|-------------------|-------------------------------------------|
| `SearchThreads` | `id`, `query`, `description`                     | `ThreadsSearched` | `mcp__claude_ai_Gmail__search_threads`    |
| `GetThread`     | `id`, `thread_id`, `description`                 | `ThreadFetched`   | `mcp__claude_ai_Gmail__get_thread`        |
| `CreateDraft`   | `id`, `to`, `subject`, `body`, `description`     | `DraftCreated`    | `mcp__claude_ai_Gmail__create_draft`      |
| `ListDrafts`    | `id`, `description`                              | `DraftsListed`    | `mcp__claude_ai_Gmail__list_drafts`       |

`EmailTool` is `identified_by :id` — the harness mints a stable ULID
before dispatch. A `Cascade` record uses the SAME id as the originating
`EmailTool` record so the outcome is joinable against the invocation by
id across aggregates.

## State versus event payload

Bodies and thread content can be thousands of bytes ; the bluebook
splits state and payload deliberately so the `.heki` does not bloat.

| Command         | Lives in aggregate state                     | Lives in event payload only            |
|-----------------|----------------------------------------------|----------------------------------------|
| `SearchThreads` | `description`                                | `query`, matched thread ids + snippets |
| `GetThread`     | `thread_id`, `description`                   | full thread body                       |
| `CreateDraft`   | `to`, `subject`, `description`               | `body` (the markdown)                  |
| `ListDrafts`    | `description`                                | the draft list (subject/to/drafted_at) |

The "drafts only, never send" operating mode is encoded by what is
NOT modelled here : there is no `SendDraft` command. Sending is the
operator's act ; Miette composes, the operator approves.

## Args mapping (i608)

Each `:mcp` binding in `tools.hecksagon` declares the args shape passed
to the Gmail MCP tool. The kernel substitutes `{attr_name}` placeholders
from the dispatched command's attrs before sending tools/call :

| EmailTool attr | Gmail MCP arg     |
|----------------|-------------------|
| `query`        | `q`               |
| `thread_id`    | `thread_id`       |
| `to`           | `to`              |
| `subject`      | `subject`         |
| `body`         | `body_markdown`   |

`ListDrafts` takes no args ; the binding declares `args: '{}'`.

The `args:` field in each binding is declared as a JSON-encoded
string literal (`'{"q":"{query}"}'`), not as a Ruby/Rust hash
literal. Two reasons : the kernel hook
(`rust/src/runtime/mcp_dispatcher/mod.rs`) already does
`serde_json::from_str(&args_raw)` on the field — it expects a JSON
string — and the Ruby + Rust hecksagon parsers render hash literals
differently (`{:k=>"v"}` vs `{ k: "v" }`), so a string literal keeps
the parity suite green.

## Dispatch examples

Every Gmail call routes through `storehouse__dispatch` (the universal
door). The bluebook IS the contract — short-form names are rejected,
the FQN is required.

### Search threads

```bash
$ storehouse hecks_conception Tools::EmailTool.SearchThreads \
    id=email-search-001 \
    query="from:joey is:unread" \
    description="find joey's pending replies"
```

### Get one thread

```bash
$ storehouse hecks_conception Tools::EmailTool.GetThread \
    id=email-get-001 \
    thread_id=thread-abc123 \
    description="fetch the OPT audit thread"
```

### Compose a draft (drafts only — never send)

```bash
$ storehouse hecks_conception Tools::EmailTool.CreateDraft \
    id=email-draft-001 \
    to=joey@example.com \
    subject="Re: OPT site fixes" \
    body="Hi Joey, the nine fixes are in." \
    description="draft reply to joey's audit"
```

### List outstanding drafts

```bash
$ storehouse hecks_conception Tools::EmailTool.ListDrafts \
    id=email-list-001 \
    description="review pending drafts"
```

Each dispatch :

1. Records the invocation as a fresh `EmailTool` record.
2. Emits the matching event (`ThreadsSearched` / `ThreadFetched` /
   `DraftCreated` / `DraftsListed`).
3. Triggers the bound `:mcp` adapter, which (once the runtime gaps
   below close) calls the Gmail MCP tool with the substituted args.
4. Cascades into `Cascade.RecordResult` carrying the same invocation
   id plus the captured Gmail-API response — `tool`, `output`,
   `exit_code`, `ok`.

## MCP-dispatch direction

```
Miette                       StoreHouse                 :mcp adapter
   |                              |                           |
   |--- Tools::EmailTool.        |                           |
   |     SearchThreads ---------->|                           |
   |    query, description        |                           |
   |                              |--- record dispatch ------>|
   |                              |--- emit ThreadsSearched   |
   |                              |--- call Gmail MCP ------->|
   |                              |<-- search hits -----------|
   |                              |--- Cascade.RecordResult ->|
   |                              |--- emit ResultRecorded    |
   |<-- dispatch result ----------|                           |
   |                                                          |
   |<== policies hook ThreadsSearched / ResultRecorded =======|
```

The `:mcp` adapter family
(`framework/adapter_families/mcp.hecksagon`) handles the MCP-shaped
transport ; per the locked principle "wiring is override, not
substrate" the bluebook composes the call (which tool, which args),
the adapter executes it.

## Runtime status — 2026-05-14

What lands today (i608 — adapter wiring) :

- The four `:mcp` adapter bindings live in
  `hecks_conception/aggregates/framework/tools/tools.hecksagon` with
  `server: :gmail`, `tool: "mcp__claude_ai_Gmail__*"`, and the
  args mapping above.
- The companion behaviors in
  `hecks_conception/aggregates/framework/tools/tools.behaviors` —
  eight tests covering the four EmailTool commands (the
  state-shaping + event-emission contract).
- Round-trip via `storehouse__dispatch` :
  - `Tools::EmailTool.SearchThreads` — lands, state records `description`,
    emits `ThreadsSearched`.
  - `Tools::EmailTool.GetThread` — lands, state records `thread_id`
    + `description`, emits `ThreadFetched`.
  - `Tools::EmailTool.CreateDraft` — lands, state records `to` +
    `subject` + `description`, emits `DraftCreated`.
  - `Tools::EmailTool.ListDrafts` — lands, state records `description`,
    emits `DraftsListed`.

What's pending — two runtime gaps before the dispatch IS the fetch
end-to-end :

1. **i594 — bluebook-driven kernel-hook registration.** Until that
   lands, `framework_registry::seed_kernel_hooks` does not seed
   `invoke_mcp_tool` and the runtime has no `resolve_mcp_adapters`
   arm parallel to `resolve_claude_tool_adapters`. So a matching
   `:mcp` binding parses into IR cleanly but the runtime does not
   auto-fire it after a dispatch. The Cascade never fires from the
   `:mcp` side today ; the bindings still serve as the contract.

2. **The `:gmail` server registry in the kernel hook.** Today the
   MCP dispatcher's `resolve_server_spawn` registers `:storehouse`
   only — a Node stdio server we own. The Claude harness's Gmail
   MCP surface is exposed through the harness, not as an
   independently-spawnable stdio server. The right path is a
   harness-side bridge (or a thin proxy that re-exports the
   harness's Gmail tools as a local stdio server). That bridge
   lands in a sibling card.

In the meantime, the bindings ARE the contract — the bluebook says
which MCP tool a given EmailTool command flows to and with which
args. When (1) and (2) close, the dispatch becomes the fetch with
no further bluebook edits.

## Related

- `hecks_conception/aggregates/framework/tools/tools.bluebook` — the
  EmailTool aggregate with all four commands (lines 419–544).
- `hecks_conception/aggregates/framework/tools/tools.hecksagon` —
  the four `:mcp` adapter bindings.
- `hecks_conception/aggregates/framework/adapter_families/mcp.hecksagon`
  — the `:mcp` adapter family declaration.
- `hecks_conception/aggregates/framework/behavior_kinds/invoke_mcp_tool.hecksagon`
  — what the kernel does on dispatch.
- `hecks_conception/inbox/i608.md` — the card naming this gap.
- `hecks_conception/inbox/i593.md` — the `:mcp` adapter family
  introduction.
- `hecks_conception/inbox/i594.md` — bluebook-driven kernel-hook
  registration (gap 1 above).
- `hecks_conception/inbox/i603.md` — the broader directive : ALL
  tool calls flow through StoreHouse.
- [`docs/usage/tools.md`](tools.md) — the sibling doc covering
  ShellTool / FileTool / SearchTool / WebTool / Cascade.
- [`docs/usage/storehouse-mcp.md`](storehouse-mcp.md) — the
  universal door (`storehouse__dispatch`) at the MCP boundary.
