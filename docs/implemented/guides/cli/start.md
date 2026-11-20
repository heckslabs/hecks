# start

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/start/start.bluebook" -->
Begin a domain or a project. Use it when you have no bluebook yet, or when you want a launcher,
a Rails app or an MCP server for one you have.

**Concept.** A domain starts as a few stub files: a bluebook, a hecksagon, and a world. A
launcher is a command line written beside a domain, so `hecks` runs that domain's commands. A
project is the set of domains in one checkout.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:Launch.project_cli!" supports="code_file:lib/hecks/hecks/start/start.bluebook" -->
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

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks start` prints the same list.

<!-- generated:begin cli section=start -->
### Launch

A way into the framework opened for a project: its launchers, or an MCP server.

- `hecks Launch.project_cli! [<domains>]`: Write a command-line launcher beside each domain of this project
- `hecks Launch.init! <name> [adapter=] [dir=]`: Write the stub files of a new domain
- `hecks Launch.project_rails! [<dir>]`: Write the controllers and routes a Rails app drives its domain through
<!-- generated:end cli -->
