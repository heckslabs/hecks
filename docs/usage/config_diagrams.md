# Config Page Domain Wiring Diagrams

The web explorer's `/config` page renders Mermaid diagrams showing domain
structure, behavior, and reactive flows.

## What you see

Three collapsible sections appear below the Aggregates table:

- **Structure** — classDiagram of aggregates, attributes, value objects, entities, and references
- **Behavior** — flowchart of commands, events, and policy chains
- **Flows** — sequenceDiagram of reactive chains (command -> event -> policy -> command)

## How it works

Diagrams are generated at **compile time** using `DomainVisualizer` and
`FlowGenerator`, then embedded as string literals in the generated server code.
The Mermaid CDN renders them client-side.

```ruby
# The generators call these internally:
vis = Hecks::DomainVisualizer.new(domain)
vis.generate_structure   # => classDiagram Mermaid string
vis.generate_behavior    # => flowchart LR Mermaid string
Hecks::FlowGenerator.new(domain).generate_mermaid  # => sequenceDiagram string
```

## Example

Boot any domain app and visit `/config`:

```bash
cd examples/pizzas_static_ruby
ruby -Ilib lib/pizzas_domain/server.rb
# open http://localhost:8080/config
```

The Structure diagram shows Pizza and Order aggregates with their attributes,
the Topping value object, and the Order -> Pizza reference arrow. The Behavior
diagram shows command-to-event flows and policy links. The Flows diagram shows
the reactive chain sequence.
