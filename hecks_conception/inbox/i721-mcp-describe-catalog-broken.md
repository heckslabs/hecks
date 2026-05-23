# i721 — describe/catalog MCP tools broken (subcommand mismatch)

The `storehouse__describe_aggregate` and `storehouse__catalog` MCP tools are wired
to `storehouse describe` and `storehouse dump` respectively. The installed `storehouse`
binary does not have a `describe` subcommand or a `dump` subcommand — it exposes
`inspect`, `tree`, `list`, and a handful of others.

Every call to these two MCP tools returns an error like "no such subcommand: describe"
(or "dump"), making them completely non-functional.

## Fix direction

Audit the installed binary's actual subcommand surface :

```
storehouse --help
```

Map the MCP tools to the subcommands that actually exist :

- `storehouse__catalog` — likely maps to `storehouse list <bluebook_root>` or
  `storehouse inspect <bluebook_root>`. Pick whichever returns full IR JSON.
- `storehouse__describe_aggregate` — likely maps to `storehouse inspect <root>
  <aggregate>` or `storehouse tree <root> <aggregate>`. Pick whichever returns a
  single aggregate's IR.

Update `storehouse-mcp/src/defs/cli/` (the tool implementation files) to call the
correct subcommands. Retest with a known bluebook (e.g. `hecks_conception` +
`ShellTool`) to confirm the output shape the MCP callers expect.

## Risk

If the binary's output shape differs from what the MCP tool's response parser
expects, the parser will also need updating. Check both the shell call and the
response parsing in the same pass.
