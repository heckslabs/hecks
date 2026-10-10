# Doors are driving adapters

**Status:** Accepted — implemented. Date: 2026-10-07. Supersedes the "door" vocabulary of [0062](0062-mcp-servers-need-real-authentication-before-any-network-transport.md), [0072](0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md) and [0089](0089-the-mcp-door-gets-a-commands-scope-and-stays-booted.md); their decisions stand under the new names.

## Context

`Hecks::Doors` held the Ruby surface a boot installs, the CLI runner, the JSON reader and the MCP server. Each is code an outside caller reaches in through, which is what hexagonal architecture calls a driving adapter, and `lib/hecks/adapters/driving/` already held the GitHub webhook receiver. One concept had two names and two homes, and "door" also served as a loose metaphor for any entry point (the router's reader, a launch record in the Custodian chapter, the dispatcher a policy re-enters through).

## Decision

1. **A door is a driving adapter.** `Hecks::Doors` moves to `Hecks::Adapters::Driving`, in `lib/hecks/adapters/driving/`, beside the webhook receiver. `RubyDoor` is `Driving::Ruby`, `CliDoor` is `Driving::Cli`, `JsonDoor` is `Driving::Json`, `McpDoor` is `Driving::Mcp` and `McpDoorScope` is `Driving::McpScope`. `CliRunner`, `Handle`, `LauncherOptions` and `CommandRequest` keep their names.
2. **The word is retired.** Nothing in the code, the bluebooks or the live docs says "door". Dated records (ADRs, the changelog, plans, audits) keep the word they were written in.
3. **Renames that follow:**
   - `install_doors:` on `boot`, `boot_files` and `boot_described` is `install_driving:`. The old keyword is refused as an unknown keyword, as `install_facade:` was.
   - The MCP server's variables are `HECKS_SERVER_TOOLS`, `HECKS_SERVER_DOMAINS` and `HECKS_SERVER_COMMANDS`. A `HECKS_DOOR_*` variable is refused by name, never ignored: ignoring `HECKS_DOOR_TOOLS=readers` would start an unrestricted server where the spawner asked for a narrow one.
   - The `.mcp.json` server `hecks-door` is `hecks-mcp`; the process name is `hecks-mcp`.
   - The Custodian's `Door` aggregate is `Launch`, with `LaunchKey`, `LaunchAnswered`, `LaunchRefused`, `LaunchStopped` and `LaunchFinished`; its commands are `launch.project_cli`, `launch.serve_mcp`, `launch.init` and `launch.interview`.
   - The policy and saga interpreters take `dispatcher:`, not `door:`.
4. **Side.** This is Ruby and the Custodian bluebook; the language is unchanged. Which driving adapters a domain takes is not yet a hecksagon declaration: a boot installs the Ruby adapter unless `install_driving: false`.

## Consequences

- A script that spawns the MCP server with `HECKS_DOOR_*`, or calls `hecks door.serve_mcp`, fails loudly and says the new name.
- A Ruby caller of `Hecks::Doors::*` gets a `NameError`.
