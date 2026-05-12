# storehouse-mcp — Tools.* as MCP

`tooling/storehouse-mcp/` is a small MCP server that exposes every
`Tools.*` command on the Hecks bus as a native MCP tool. Combined
with project-level deny rules on native `Bash` / `Read` / `Edit` /
`Write` / `Grep` / `Glob`, the MCP becomes the only dispatch channel
Claude has — every filesystem and shell operation flows through the
bus, every operation emits a domain event, every operation is
audited as a Tools aggregate record.

## Why

The discipline is from the `Tools.bluebook` (`hecks_conception/aggregates/framework/tools/tools.bluebook`):

> First-class tool invocations as dispatched commands. […] This
> bluebook lifts each invocation into a domain command so every tool
> use emits an event the runtime can react to.

Before this MCP existed, the Tools.* dispatches were available but
optional — Claude could call native `Bash` and the bus would see
nothing. With the MCP installed and the native tools denied at the
project layer, the discipline is structural rather than aspirational.
Claude has no escape hatch.

## The nine tools

| MCP tool name                       | Dispatches             | Maps to native |
|-------------------------------------|------------------------|----------------|
| `mcp__storehouse__storehouse__bash`         | `Tools.Bash`           | `Bash`         |
| `mcp__storehouse__storehouse__read`         | `Tools.Read`           | `Read`         |
| `mcp__storehouse__storehouse__edit`         | `Tools.Edit`           | `Edit`         |
| `mcp__storehouse__storehouse__update`       | `Tools.Update`         | `Write`        |
| `mcp__storehouse__storehouse__grep`         | `Tools.Grep`           | `Grep`         |
| `mcp__storehouse__storehouse__glob`         | `Tools.Glob`           | `Glob`         |
| `mcp__storehouse__storehouse__web_fetch`    | `Tools.WebFetch`       | `WebFetch`     |
| `mcp__storehouse__storehouse__web_search`   | `Tools.WebSearch`      | `WebSearch`    |
| `mcp__storehouse__storehouse__record_result`| `Tools.RecordResult`   | (kernel hook)  |

Every tool takes a stable `id` (ULID-ish ; the bluebook persists by
id so RecordResult joins back to the originating dispatch) plus an
optional `description`. The tool-specific attrs match the bluebook
command contract exactly.

## Setup

The MCP is wired up by two files at the project root :

1. `.mcp.json` registers the server with Claude Code as a stdio MCP.
2. `.claude/settings.json` denies the native Bash / Read / Edit /
   Write / Grep / Glob / WebFetch / WebSearch tools and allows the
   nine `mcp__storehouse__*` tools.

### First-time install

```sh
cp .mcp.json.example .mcp.json
cd tooling/storehouse-mcp
npm install
```

The `.mcp.json` file is gitignored (it can contain user-specific
credentials) so the committed template is `.mcp.json.example`. Copy
it once per checkout.

Then start a new Claude Code session in the project root. The first
time, Claude will prompt to approve the project-scoped MCP server.
After approval, the storehouse tools become available and the native
ones return permission-denied.

### Verifying

```sh
cd tooling/storehouse-mcp
npm run smoke
```

Boots the server in a sub-process, lists tools, dispatches
`storehouse__bash` + `storehouse__read` + `storehouse__record_result`,
asserts each round-trip carries the expected aggregate state. Exit 0
on green.

### Manual probe

You can also dispatch directly via the CLI to confirm the underlying
contract :

```sh
storehouse hecks_conception Tools.Bash shell_command="echo mcp-test" id=manual-001
# → [claude_tool:bash] ok=true exit=0 output="mcp-test\n"
#   {"aggregate":"Tools","id":"manual-001","ok":true,"state":{...}}
```

## Env vars

| Var                          | Default            | What it does |
|------------------------------|--------------------|--------------|
| `STOREHOUSE_BIN`             | `storehouse`       | Path to the storehouse binary (default uses `$PATH`) |
| `STOREHOUSE_ROOT`            | auto-resolved      | Bluebook root dir. Walks up from the MCP source to find `hecks_conception/` when unset |
| `STOREHOUSE_MCP_QUALIFIED`   | `false`            | When `true`, uses fully-qualified dispatch paths (`framework::tools::ShellTool::Bash` etc) — flip on once the Tools.bluebook split merges to main |

## How it works

```
Claude tool call             MCP server                  storehouse CLI            Runtime
─────────────────────────────────────────────────────────────────────────────────────────────
storehouse__bash(           → registerTool handler →    spawn("storehouse",   →    dispatches
  id="t1",                                              "hecks_conception",        Tools.Bash,
  shell_command="echo hi")                              "Tools.Bash",              emits BashRan,
                                                        "id=t1",                   :claude_tool
                                                        "shell_command=...")       hook runs shell
                            ← parsed JSON state ←       ← stdout JSON line ←       ← stdout/exit
content + structuredContent ←
```

The MCP is a thin wrapper. It owns no domain logic ; it spawns the
storehouse binary, parses the JSON line out of stdout (skipping the
`[claude_tool:...]` side-effect trace lines), and returns the parsed
object as the tool response's `structuredContent`. Side-effect lines
and raw stdout/stderr are returned too for debugging.

## Files

| Path                                            | What it is |
|-------------------------------------------------|------------|
| `tooling/storehouse-mcp/src/server.mjs`         | MCP server entry — boots `McpServer`, registers tools, connects stdio transport |
| `tooling/storehouse-mcp/src/tools.mjs`          | Tool registry — name, description, Zod input schema, encode fn, verb |
| `tooling/storehouse-mcp/src/dispatch.mjs`       | The `storehouse` shell-out — spawns the CLI, parses JSON, returns the result |
| `tooling/storehouse-mcp/test/smoke.mjs`         | End-to-end smoke test, MCP-protocol level |
| `tooling/storehouse-mcp/package.json`           | npm manifest |
| `.mcp.json.example`                             | Committed template ; copy to `.mcp.json` (which is gitignored) to register the server |
| `.claude/settings.json`                         | Deny native tools, allow `mcp__storehouse__*` |

## See also

- `hecks_conception/aggregates/framework/tools/tools.bluebook` — the contract
- [`docs/usage/tools.md`](tools.md) — the dispatch story end-to-end
- `hecks_conception/inbox/i552.md` — Claude → StoreHouse direction
