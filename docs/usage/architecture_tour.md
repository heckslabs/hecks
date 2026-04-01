# Architecture Tour

A guided CLI walkthrough of the Hecks framework internals for contributors.

## Usage

```bash
hecks tour --architecture
```

## What it covers

The tour walks through 10 steps:

1. **Monorepo layout** -- the six component gems
2. **Bluebook DSL** -- builders, validators, domain definitions
3. **Hecksagon IR** -- the intermediate representation (Domain, Aggregate, Command, etc.)
4. **Compiler pipeline** -- from domain.rb through validation to code generation
5. **Hecksties glue** -- Thor CLI, command registration, domain helpers
6. **Code generators** -- Ruby, Go, and Node targets with cross-target parity
7. **Workshop** -- sketch mode, play mode, and the interactive REPL
8. **AI tools** -- MCP server for agent-driven domain modeling
9. **CLI registration** -- how commands are discovered and grouped
10. **Spec conventions** -- memory adapters, speed constraints, test layout

Each step displays relevant file paths and pauses for Enter (skipped in CI).

## Without the flag

```bash
hecks tour
```

Runs the domain modeler's walkthrough (sketch -> play -> build loop).
