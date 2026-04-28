# entity — non-root entity inside an aggregate

The `entity` keyword declares an entity that lives **inside** an aggregate
root rather than being one. Use it when you need identity-bearing parts
that exist only in the context of their parent — they have a stable
identifier, can be mutated independently, but never exist as standalone
records in the heki store.

It mirrors `value_object` in syntax but adds identity. Where a value
object is replaced wholesale (no identity, immutable from the outside),
an entity has its own id and can be addressed and mutated by that id
within the parent.

## When to reach for `entity`

| Concern                                  | Use                |
|------------------------------------------|--------------------|
| Identity-bearing top-level concept       | `aggregate`        |
| Identity-bearing part inside an aggregate| `entity`           |
| No identity, immutable, replaced whole   | `value_object`     |

If you find yourself wanting to "address one of these by id" but it only
makes sense within a parent — that's an entity, not a sub-aggregate.

## Syntax

```ruby
aggregate "Cli", "The CLI subcommand surface" do
  identified_by :pid_started_at
  attribute :pid_started_at, String
  attribute :argv,           list_of(String)

  entity "Phase" do
    attribute :name,          String
    attribute :started_at,    String
    attribute :ended_at,      String
    attribute :status,        String
    attribute :error_message, String
  end
end
```

The example above is from `hecks_conception/capabilities/cli/cli.bluebook`.
A `Phase` represents one step of CLI execution (parse → resolve →
dispatch → emit). Each phase has its own identity within the running
CLI invocation but never exists outside of it — there's no
`Phase` heki store, no `Phase.Add` command at the top level. It lives
under the `Cli` root.

## What the runtime does with it

- Adds a `pub entities: Vec<Entity>` field to the `Aggregate` IR struct
  (mirror of `pub value_objects: Vec<ValueObject>`).
- The parser dispatches `entity` blocks to `parse_entity` (mirror of
  `parse_value_object`).
- `dump.rs` emits an `entities` array alongside `value_objects` in
  the canonical IR.
- Generated Ruby and Rust outputs treat entities as nested types with
  their own id — no separate aggregate root, no top-level commands.

## How it differs from `value_object`

```ruby
value_object "Address" do
  attribute :street, String
  attribute :city,   String
end
```

An `Address` is replaced wholesale: every command that takes an Address
gets a new one and discards the old. There's no "the same address with
a corrected ZIP" — there's only "a new address that looks mostly like
the old one."

```ruby
entity "Phase" do
  attribute :name, String
  attribute :status, String
end
```

A `Phase` keeps its identity across mutations. The `dispatch` phase that
started at 10:32:01 is the same phase whether its status is `running`,
`succeeded`, or `failed`. Entities support fine-grained mutation;
value objects don't.

## Notes

- An entity's identity is implicit (whatever uniquely names it within
  the parent). The runtime doesn't currently require a top-level
  `identified_by` on an entity declaration; the parent aggregate's
  identity scopes the entity.
- Tests under `hecks_life/tests/` exercise the `entities: vec![]`
  default for aggregates without entity declarations — keeping the
  IR struct consistent across both paths.
