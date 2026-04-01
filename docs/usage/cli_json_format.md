# CLI JSON Format

Several CLI commands support `--format json` for machine-readable output,
useful for IDE integration, Studio consumption, and CI pipelines.

## Commands with JSON support

### hecks validate --format json

```bash
hecks validate --format json
```

```json
{
  "valid": true,
  "domain": "Pizzas",
  "aggregates": [
    {
      "name": "Pizza",
      "attributes": ["name", "description"],
      "commands": ["CreatePizza"],
      "events": ["CreatedPizza"]
    }
  ],
  "errors": [],
  "warnings": []
}
```

### hecks inspect --format json

```bash
hecks inspect --format json
hecks inspect --format json --aggregate Order
```

```json
{
  "domain": "Shop",
  "aggregates": [
    {
      "name": "Order",
      "attributes": [
        { "name": "name", "type": "String" },
        { "name": "total", "type": "Float" }
      ],
      "commands": [
        { "name": "CreateOrder", "attributes": [{ "name": "name", "type": "String" }] }
      ],
      "events": ["OrderCreated"],
      "value_objects": ["LineItem"]
    }
  ]
}
```

### hecks tree --format json

```bash
hecks tree --format json
```

Returns all registered commands grouped by source module. See `docs/usage/cli_tree.md`.

### hecks stats --json

```bash
hecks stats --json
```

Returns comprehensive project statistics as JSON.
