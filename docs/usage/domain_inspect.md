# Domain Inspect

Show the full domain definition including business logic, formatted for terminal reading.

## Usage

```bash
# Inspect the full domain
hecks inspect

# Inspect a specific aggregate
hecks inspect --aggregate Order

# Inspect a domain by path
hecks inspect --domain path/to/domain
```

## Output Sections

Per aggregate: attributes, value objects, entities, lifecycle (field, default, transitions), commands (params, events, preconditions, postconditions, body), events, queries, validations, invariants, policies (guard + reactive with source), scopes, specifications, subscribers, references.

Domain-level: policies, services, views, workflows, sagas, actors, glossary rules.

## Example Output

```
Domain: Shop
============

Aggregate: Order
=================

  Attributes:
    name: String
    status: String

  Value Objects:
    LineItem (product: String, qty: Integer)

  Lifecycle:
    field: status, default: "draft"
    states: draft, placed
    transitions:
      PlaceOrder -> placed

  Commands:
    CreateOrder(name: String) -> emits CreatedOrder
    PlaceOrder() -> emits PlacedOrder

  Invariants:
    name must be present: !name.nil? && !name.empty?

  Policies:
    HighValue: guard — cmd.respond_to?(:name)
```
