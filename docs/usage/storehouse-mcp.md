# storehouse-mcp — universal bluebook bus as MCP

`tooling/storehouse-mcp/` is a Node-based MCP server that exposes the
Hecks bluebook bus to Claude Code. The surface is intentionally tiny :
one universal dispatcher plus discovery and developer-workflow tools.
The LLM constructs verb strings dynamically from the IR catalog ;
nothing is hand-registered per bluebook command.

## Why

The discipline comes from the Tools bluebook
(`hecks_conception/aggregates/framework/tools/`):

> First-class tool invocations as dispatched commands. This bluebook
> lifts each invocation into a domain command so every tool use emits
> an event the runtime can react to.

Every filesystem and shell operation flows through the bus as a
`Tools::ShellTool.Bash`, `Tools::FileTool.Read`, etc. dispatch —
each one emits a domain event, each one is audited as an aggregate
record. The MCP makes that structural : Claude has no escape hatch.

## The ten tools

| MCP tool name                              | CLI subcommand                           | Purpose |
|--------------------------------------------|------------------------------------------|---------|
| `storehouse__dispatch`                     | `storehouse <root> <FQN.Command> k=v …`  | Universal command door — any bluebook command |
| `storehouse__query`                        | `storehouse query <root> <FQN.verb> k=v …` | Read-only counterpart ; enforces snake_case verb-tail |
| `storehouse__state`                        | `storehouse state <root> <Aggregate> <id>` | Read a single aggregate record |
| `storehouse__catalog`                      | `storehouse dump <bluebook>`             | Full canonical-IR JSON for one bluebook |
| `storehouse__describe_aggregate`           | `storehouse describe <bluebook> <agg>`   | Canonical-IR JSON for one aggregate |
| `storehouse__list_aggregates`              | `storehouse parse <bluebook>`            | Aggregate names + counts |
| `storehouse__validate`                     | `storehouse validate <bluebook>`         | Parse + DDD consistency check |
| `storehouse__macrophage_check`             | `storehouse macrophage` (stdin)          | Spot-check a file path against the macrophage |
| `storehouse__behaviors`                    | `storehouse behaviors <path>`            | Run a `.behaviors` test suite |
| `storehouse__conceive_behaviors`           | `storehouse conceive <bluebook>`         | Generate a behaviors companion |

## FQN address format

Commands and queries require a fully-qualified name :

```
Domain::Aggregate.Command       # PascalCase tail → command
Domain::Aggregate.snake_case    # snake_case tail → query
```

Examples of required FQNs :

| Old short-form (retired) | Required FQN |
|--------------------------|--------------|
| `Tools.Bash`             | `Tools::ShellTool.Bash` |
| `Tools.Read`             | `Tools::FileTool.Read` |
| `Tools.Edit`             | `Tools::FileTool.Edit` |
| `Tools.Grep`             | `Tools::SearchTool.Grep` |
| `Tools.WebFetch`         | `Tools::WebTool.WebFetch` |
| `Tools.RecordResult`     | `Tools::Cascade.RecordResult` |

Bare `Command` or `Aggregate.Command` (no `Domain::` prefix) returns
an "short-form address" error from the runtime.

## Calling pattern — three-zoom discovery

The LLM discovers what is callable through nested zooms before
dispatching :

1. `storehouse__list_aggregates` — find the aggregate names in a bluebook.
2. `storehouse__describe_aggregate` — full IR for one aggregate (commands, queries, attributes, value objects, lifecycle).
3. `storehouse__catalog` — full IR for the whole bluebook when a wide-angle index is needed.

Then construct the FQN verb string and call `storehouse__dispatch` (or
`storehouse__query` for explicit read-only intent). The runtime
auto-detects command vs. query from the bluebook's lexicon ; the query
tool is a shape-gated alias.

## Resources

`storehouse://events` — live tail of `$HECKS_AGENT_EVENT_STREAM`
(default `/tmp/miette_agent_events.jsonl`). Subscribe to receive
`notifications/resources/updated` whenever the file grows ; then call
`resources/read` to fetch new content.

## Setup

The server is registered in `$PROJECT_ROOT/.mcp.json` (project-scoped).
Claude Code reads this on startup.

### First-time install

```sh
cp .mcp.json.example .mcp.json
cd /Users/christopheryoung/Projects/hecks/tooling/storehouse-mcp
npm install
```

`.mcp.json` is gitignored (may contain user-specific paths). The
committed template is `.mcp.json.example`. Copy it once per checkout,
then restart Claude Code to load the server.

### Verifying

```sh
# Full smoke — boots server, lists tools/resources, exercises every
# tool, subscribes to events, asserts resources/updated fires.
node /Users/christopheryoung/Projects/hecks/tooling/storehouse-mcp/test/cli_smoke.mjs

# Sanity-boot only (no MCP frames sent) :
node /Users/christopheryoung/Projects/hecks/tooling/storehouse-mcp/src/server.mjs < /dev/null
# → [storehouse-mcp] connected, 10 tools + storehouse://events resource registered
```

## Env vars

| Var                        | Default            | What it does |
|----------------------------|--------------------|--------------|
| `STOREHOUSE_BIN`           | `storehouse`       | Path to the storehouse binary (default uses `$PATH`) |
| `STOREHOUSE_ROOT`          | auto-resolved      | Bluebook root dir ; walks up from MCP source to find `hecks_conception/` when unset |
| `HECKS_AGENT_EVENT_STREAM` | `/tmp/miette_agent_events.jsonl` | JSONL file the runtime writes events to ; must match on both sides |

## How it works

```
Claude tool call                  MCP server               storehouse CLI      Runtime
──────────────────────────────────────────────────────────────────────────────────────
storehouse__dispatch(           → CLI runner →            spawn(          →   dispatches
  root="hecks_conception",                                "storehouse",       Tools::ShellTool.Bash,
  command="Tools::ShellTool.Bash",                        "hecks_conception", emits BashRan,
  args={id:"t1",                                          "Tools::ShellTool.Bash", :claude_tool
        shell_command:"echo hi"})                         "id=t1",            hook runs shell
                                                          "shell_command=…")
                                ← parsed JSON state ←    ← stdout JSON ←     ← stdout/exit
structuredContent ←
```

The MCP is a thin wrapper. It owns no domain logic ; it spawns the
storehouse binary, parses the JSON state line from stdout (skipping
`[claude_tool:…]` side-effect trace lines), and returns the parsed
object as `structuredContent`. Raw stdout/stderr are included for
debugging.

## Examples

### Dispatch a shell command through the bus

```jsonc
// storehouse__dispatch
{
  "root": "hecks_conception",
  "command": "Tools::ShellTool.Bash",
  "args": {
    "id": "t1",
    "shell_command": "echo mcp-test"
  }
}
// → { "ok": true, "aggregate": "ShellTool", "id": "t1",
//     "state": { "exit": 0, "output": "mcp-test\n" } }
```

### Discovery flow — three-zoom calling pattern

```jsonc
// 1. What aggregates live in the Tools domain?
// storehouse__list_aggregates
{ "bluebook": "hecks_conception/aggregates/framework/tools/shell_tool.bluebook" }
// → { "aggregates": ["ShellTool"], "command_count": 3, "query_count": 1 }

// 2. What commands does ShellTool expose?
// storehouse__describe_aggregate
{
  "bluebook": "hecks_conception/aggregates/framework/tools/shell_tool.bluebook",
  "aggregate": "ShellTool"
}
// → full IR: commands, queries, attributes, value objects, lifecycle

// 3. Dispatch now that the schema is known.
// storehouse__dispatch
{
  "root": "hecks_conception",
  "command": "Tools::ShellTool.Bash",
  "args": { "id": "t1", "shell_command": "echo hello" }
}
```

### Read a specific record by id

```jsonc
// storehouse__state
{
  "root": "hecks_conception",
  "aggregate": "ShellTool",
  "id": "t1"
}
// → { "ok": true, "aggregate": "ShellTool", "id": "t1",
//     "state": { "exit": 0, "output": "hello\n" } }
// Missing record: ok:false, state:null — not an error.
```

### Query with snake_case verb (read-only)

```jsonc
// storehouse__query — accepted (snake_case tail)
{
  "root": "hecks_conception",
  "command": "Tools::ShellTool.recent_runs",
  "args": { "limit": "5" }
}

// storehouse__query — rejected (PascalCase tail is a command, not a query)
{
  "root": "hecks_conception",
  "command": "Tools::ShellTool.Bash",   // ← error: PascalCase tail disallowed in query tool
  "args": { "id": "t1", "shell_command": "echo hi" }
}
```

## Troubleshooting

- **Tools don't appear after restart** — check Claude Code's MCP
  diagnostics panel. The server's stderr line
  `[storehouse-mcp] connected, …` should appear there.
- **`storehouse: command not found`** — set `STOREHOUSE_BIN` to the
  absolute path. The `.mcp.json` already points at
  `$PROJECT_ROOT/rust/target/release/storehouse`.
- **No events arriving** — confirm `HECKS_AGENT_EVENT_STREAM` matches
  what the runtime writes and what the MCP server reads. Both sides
  must agree on the path.
- **"short-form address" error from dispatch** — the runtime requires
  `Domain::Aggregate.Command` (PascalCase) or
  `Domain::Aggregate.snake_case` (queries). Bare `Command` or
  `Aggregate.Command` no longer works.

## Files

| Path                                                    | What it is |
|---------------------------------------------------------|------------|
| `tooling/storehouse-mcp/src/server.mjs`                 | stdio MCP server — registers tools + events resource |
| `tooling/storehouse-mcp/src/tools.mjs`                  | Tool registry (all 10 CLI-shaped tools) |
| `tooling/storehouse-mcp/src/cli_dispatch.mjs`           | Shared `storehouse <subcommand>` runner |
| `tooling/storehouse-mcp/src/events.mjs`                 | `storehouse://events` resource + JSONL tail watcher |
| `tooling/storehouse-mcp/src/defs/cli/*.mjs`             | One def per tool (10 files) |
| `tooling/storehouse-mcp/test/cli_smoke.mjs`             | End-to-end smoke test |
| `.mcp.json.example`                                     | Committed template ; copy to `.mcp.json` to register |
| `.claude/settings.json`                                 | Deny native tools, allow `mcp__storehouse__*` |

## See also

- `hecks_conception/aggregates/framework/tools/` — the bluebook contracts
- [`docs/usage/tools.md`](tools.md) — the dispatch story end-to-end
- `tooling/storehouse-mcp/SETUP.md` — installation reference
