# CLI Tree Command

Print all registered CLI commands grouped by source module.

## Usage

```bash
# Text tree output
hecks tree

# JSON output for tooling/Studio
hecks tree --format json
```

## Text Output Example

```
Hecks CLI Commands

Cli/
  |-- build  [--domain, --version, --target, --static]  # Generate the domain gem
  |-- inspect  [--domain, --aggregate, --format]  # Show full domain definition
  |-- validate  [--domain, --format]  # Validate the domain definition
  \-- tree  [--format]  # Print all commands as a grouped tree

Workshop/
  |-- console  # Start the interactive workshop
  \-- web_workshop  # Start the browser-based workshop
```

## JSON Output Example

```bash
hecks tree --format json
```

```json
{
  "Cli": [
    { "name": "build", "description": "Generate the domain gem", "options": ["domain", "version", "target", "static"] },
    { "name": "validate", "description": "Validate the domain definition", "options": ["domain", "format"] }
  ]
}
```
