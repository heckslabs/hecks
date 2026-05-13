# storehouse-mcp — SETUP

## What

A Node-based MCP server that exposes the Hecks bluebook bus to Claude
Code. The surface is intentionally tiny : one universal dispatcher
plus discovery and developer-workflow tools. The LLM constructs verb
strings dynamically from the IR catalog ; nothing is hand-registered
per bluebook command.

### Tools surface (10 tools)

**Dispatch — the universal door:**

- `storehouse__dispatch` — `storehouse <root> <Domain::Aggregate.Command> k=v ...` ; runs any bluebook command on any aggregates root.
- `storehouse__query` — `storehouse query <root> <Domain::Aggregate.snake_case> k=v ...` ; read-only counterpart, enforces snake_case verb-tail.

**Read-only state probe:**

- `storehouse__state` — `storehouse state <root> <Aggregate> <id>` ; returns `{ ok, aggregate, id, state }`. Missing record is `ok:false` with `state:null` (not an error).

**Discovery — IR catalog at three zoom levels:**

- `storehouse__catalog` — `storehouse dump <bluebook>` ; full canonical-IR JSON for one bluebook.
- `storehouse__describe_aggregate` — `storehouse describe <bluebook> <aggregate>` ; canonical-IR JSON for one aggregate.
- `storehouse__list_aggregates` — `storehouse parse <bluebook>` ; aggregate names + counts.

**Developer workflow:**

- `storehouse__validate` — `storehouse validate <bluebook>` ; parse + DDD consistency check.
- `storehouse__macrophage_check` — `storehouse macrophage` with synthesized stdin ; spot-check a file path against the macrophage.
- `storehouse__behaviors` — `storehouse behaviors <path>` ; run a `.behaviors` test suite.
- `storehouse__conceive_behaviors` — `storehouse conceive <bluebook>` (behaviors mode) ; generate a behaviors companion.

### Resources surface

- `storehouse://events` — live tail of `$HECKS_AGENT_EVENT_STREAM`
  (default `/tmp/miette_agent_events.jsonl`). Subscribe to receive
  `notifications/resources/updated` whenever the file grows ; then
  call `resources/read` to fetch the new content.

## Calling pattern

The LLM discovers what's callable through three nested zooms :

1. `storehouse__list_aggregates` — find the aggregate names in a bluebook.
2. `storehouse__describe_aggregate` — full IR for one aggregate (commands, queries, attributes, value objects, lifecycle).
3. `storehouse__catalog` — full IR for the whole bluebook when the LLM needs a wide-angle index.

Then the LLM constructs the verb string and calls `storehouse__dispatch` (or `storehouse__query` for read-only verbs). The runtime auto-detects query vs. command via the bluebook's lexicon ; the query tool is a shape-gated alias so callers can be explicit about intent.

## Activating in Claude Code

The server is registered in `/Users/christopheryoung/Projects/hecks/.mcp.json`
(project-scoped). Claude Code reads this on startup.

**Restart Claude Code** to load the server.

After restart the `storehouse__*` tools appear in the agent's tool
surface, and `notifications/resources/updated` events from i17 arrive
automatically once the agent subscribes to `storehouse://events`.

## Verifying

```bash
# Boots the server, lists tools/resources, exercises every tool,
# subscribes to events, asserts the resources/updated frame fires.
cd /Users/christopheryoung/Projects/hecks/tooling/storehouse-mcp
node test/cli_smoke.mjs

# Sanity-boot only (no MCP frames sent) :
node src/server.mjs < /dev/null
# → [storehouse-mcp] connected, 10 tools + storehouse://events resource registered
```

## Troubleshooting

- **Tools don't appear after restart** — check Claude Code's MCP
  diagnostics panel. The server's stderr line
  `[storehouse-mcp] connected, …` should appear in its logs.
- **`storehouse: command not found`** — set `STOREHOUSE_BIN` to the
  absolute path. The `.mcp.json` already points at
  `/Users/christopheryoung/Projects/hecks/rust/target/release/storehouse`.
- **No events arriving** — confirm the JSONL file path matches what
  the runtime writes to. The runtime side honors `HECKS_AGENT_EVENT_STREAM` ;
  the MCP server side honors the same var. They must agree.
- **`dispatch` returns "short-form address" error** — the runtime
  requires `Domain::Aggregate.Command` (commands, PascalCase) or
  `Domain::Aggregate.snake_case` (queries). Bare `Command` or
  `Aggregate.Command` no longer works.

## Files

- `src/server.mjs` — stdio MCP server, registers tools + events resource
- `src/tools.mjs` — tool registry (collects all 10 CLI-shaped tools)
- `src/cli_dispatch.mjs` — shared `storehouse <subcommand>` runner
- `src/events.mjs` — `storehouse://events` resource + JSONL tail watcher
- `src/defs/cli/*.mjs` — one def per tool (10 files)
- `test/cli_smoke.mjs` — end-to-end smoke

## History

The 2026-05-12 rip : nine hand-registered `Tools.*` sugar wrappers
(`storehouse__bash`, `_read`, `_edit`, `_update`, `_grep`, `_glob`,
`_web_fetch`, `_web_search`, `_record_result`) were deleted along with
`src/dispatch.mjs` and the bus-tool smoke. Each one re-stated a
schema the bluebook already declared ; that's a duplication of
contract. The bluebook IS the contract — the MCP layer just projects
it. `storehouse__dispatch_command` was renamed to `storehouse__dispatch`,
and `storehouse__list` was retired in favour of structured
`storehouse__catalog` / `storehouse__describe_aggregate`.
