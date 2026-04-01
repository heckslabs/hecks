# Web Console

A browser-based REPL for the Hecks Workshop. Same features as the terminal console, but with a visual domain tree and live event log.

## Usage

```bash
hecks web_console Pizzas
# => Hecks Web Console: http://localhost:4567
```

Open `http://localhost:4567/hecks_web_workbench` in your browser. You'll see three panels:

- **Left sidebar** — Domain tree showing aggregates, attributes, commands, events
- **Center** — Terminal-like REPL input and output, with interactive domain diagram
- **Right sidebar** — Event log (populated in play mode)

## Security

The console endpoint is disabled by default. To enable command execution, pass `--enable-console`:

```bash
hecks web_console Pizzas --enable-console
```

Without this flag, POST requests to `/command` return 403. All input is parsed through `BlueBook::Grammar` — only whitelisted domain commands execute. Methods like `system`, `eval`, `exec`, `send`, and `require` are blocked at the grammar level.

## Options

```bash
hecks web_console Pizzas --port 3000
hecks web_console Pizzas --enable-console   # enable command execution
```

## Multi-Domain

Load multiple domain files into a single console:

```ruby
Hecks::Workshop::WebRunner.new(
  name: "Governance",
  domains: [
    "examples/governance/compliance_domain/hecks_domain.rb",
    "examples/governance/model_registry_domain/hecks_domain.rb",
    "examples/governance/operations_domain/hecks_domain.rb"
  ]
).run
```

Aggregates are grouped by their source domain in the sidebar and diagram.

## Example Session

Type commands in the input field at the bottom of the terminal:

```
> Pizza
Pizza aggregate created

> Pizza.name String
name attribute added to Pizza

> Pizza.create
CreatePizza command added

> validate
Valid (1 aggregates, 1 commands, 1 events)

> play!
Entering play mode...

> Pizza.create(name: "Margherita")
Command: CreatePizza
  Event: CreatedPizza

> events
1. CreatedPizza at 2026-03-29 14:32:10 UTC

> sketch!
Back to sketch mode
```

The domain tree and event log update automatically after each command.

## Keyboard Shortcuts

- **Enter** — Submit command
- **Up/Down** — Navigate command history
