# serve

Open something on a port or stdio. Use it to run the Composer, a preview of a static site, the
banking example's forms, or an MCP server.

**Status: not yet a module.** The servers are listed today under other aggregates. Until step 5
of ADR 0163 moves them, use the commands below. The module page will name the new ones then.

**Concept.** A server holds a port open until you stop it, or until the client on stdio closes.
Each one answers the same kind of request its name says.

**Example: open the Composer on a domain**

```sh
hecks CorpusRun.compose! directory.value=examples/banking
```

Serves a live bluebook editor over the domain directory, on a local port.

**Example: preview a folder of static files**

```sh
hecks CorpusRun.preview! directory.value=site/dist port.value=4000
```

**Example: serve the MCP tools over stdio**

```sh
hecks mcp! stdio.value=true
```
