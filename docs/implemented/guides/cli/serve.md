# serve

Open something on a port or stdio. Use it to run the Composer, a preview of a static site, the
banking example's forms, or an MCP server.

**Status: a module.** The servers are commands of the `Server` aggregate (`exe/hecks serve`):
`present!`, `compose!`, `preview!`, `serve_query_ir_mcp!` and `serve_mcp!`, moved there by ADR 0163 in 7.0.0.

**Concept.** A server holds a port open until you stop it, or until the client on stdio closes.
Each one answers the same kind of request its name says.

**Example: open the Composer on a domain**

```sh
hecks Server.compose! directory.value=examples/banking
```

Serves a live bluebook editor over the domain directory, on a local port.

**Example: preview a folder of static files**

```sh
hecks Server.preview! directory.value=site/dist port.value=4000
```

**Example: serve the MCP tools over stdio**

```sh
hecks mcp! stdio.value=true
```
