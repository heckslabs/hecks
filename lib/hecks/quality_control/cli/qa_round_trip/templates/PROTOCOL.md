# Command protocol

The program reads one JSON document from stdin: an array of steps. It writes one JSON object per line to
stdout: one line per step, in order, then one final `state` line. Nothing else goes to stdout.

## A step

```json
{ "command": "Order.Place", "args": { "number": "O1", "customer": "C1" } }
{ "command": "Order.Line.Price", "args": { "order": "O1", "position": 2, "cents": 450 } }
{ "query": "Order.Open", "args": {} }
```

- `command` is `Aggregate.Command`, or `Aggregate.Entity.Command` for a command on an entity inside an
  aggregate, with the names the spec uses.
- `args` holds plain JSON values: strings, numbers, booleans or null. A field the spec types with a
  single-field value object is passed as that field's plain value (`"number": "O1"`, not
  `{ "value": "O1" }`).
- A command that acts on an existing record names it by the reference key: the aggregate's name in
  snake_case (`"order": "O1"`). A command that refers to another aggregate does the same.
- An entity command names its aggregate by the reference key and the entity by its identity field.
- Steps may be malformed on purpose: a missing or unknown argument, a value of the wrong type or outside its
  rules, a record that does not exist. The spec decides what happens.

## A step's output line

```json
{ "step": 0, "ok": true, "events": ["OrderPlaced"] }
{ "step": 1, "ok": false, "events": [] }
{ "step": 2, "ok": true, "rows": [ { "number": "O1", "status": "open" } ] }
```

- `ok` is false when the command is refused. A refused command changes nothing and emits nothing.
- `events` lists every event that happened because of the step, in order, including events from any reaction
  the step set off, named exactly as the spec names them.
- A query step answers `rows`: each matching record as a flat object (see below), in the query's order.

## The final line

```json
{ "state": { "Order": [ ... ], "Customer": [ ... ] } }
```

Every record of every aggregate, sorted by identity. A record is a flat object of its fields with plain values
(value objects unwrapped to their single field), a reference as the referenced record's identity, a lifecycle
field by its name, an unset optional field as null, and a list of entities as an array of flat objects sorted
by their identity.
