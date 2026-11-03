# start

Begin a domain or a project. Use it when you have no bluebook yet, or when you want a launcher,
a Rails app or an MCP server for one you have.

**Concept.** A domain starts as a few stub files: a bluebook, a hecksagon, and a world. A
launcher is a command line written beside a domain, so `hecks` runs that domain's commands. A
project is the set of domains in one checkout.

**Example: write the stub files of a new domain**

```sh
hecks init! name.value=Library dir.value=examples/library
```

Writes the bluebook and its wiring under the directory you name.

**Example: write a launcher beside a domain**

```sh
hecks Launch.project_cli! domains.value=examples/library
```

Name the domain. Leaving `domains.value` out writes a launcher beside every domain in the
checkout, which is rarely what you want.

**Example: serve the domain's MCP tools over stdio**

```sh
hecks mcp! stdio.value=true
```

Serves the storehouse bus to an MCP client until the client closes it.
