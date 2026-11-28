# serve

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/serve/serve.bluebook" -->
Open something on a port or stdio. Use it to run a preview of a static site, the banking
example's forms, or an MCP server.

**Status: not yet a module.** The servers are listed today under other aggregates. Until step 5
of ADR 0163 moves them, use the commands below. The module page will name the new ones then.

**Concept.** A server holds a port open until you stop it, or until the client on stdio closes.
Each one answers the same kind of request its name says.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:Server.preview!" supports="code_file:lib/hecks/hecks/serve/serve.bluebook" -->
**Example: preview a folder of static files**

```sh
hecks Server.preview! directory.value=site/dist port.value=4000
```

**Example: serve the MCP tools over stdio**

```sh
hecks mcp! stdio.value=true
```

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks serve` prints the same list.

<!-- generated:begin cli section=serve -->
### Server

One server opened on a checkout, until it is stopped.

- `hecks Server.present! [<port>]`: Serve the banking example's rendered forms and views on a local port until stopped
- `hecks Server.preview! <directory> [port=]`: Serve one directory of static files, such as a website, on a local port until stopped
- `hecks Server.serve_query_ir_mcp!`: Serve the IR queries to an MCP client over stdio until it closes
- `hecks mcp! [--stdio]`: Serve the storehouse bus to an MCP client over stdio until it closes
<!-- generated:end cli -->
