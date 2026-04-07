# Bluebook Glossary

Print the Ubiquitous Language for an entire Bluebook — binding + all chapters.

## Usage

```ruby
# Get the Hecks self-describing bluebook
bluebook = Hecks::Chapters.bluebook

# Print the full glossary
bluebook.glossary
```

Output:

```
── Binding ──
  ModuleDSL — Declarative lazy_registry helper for modules
    DefineRegistry
  CoreExtensions — Shared mixins: Describable, AttributeCollector
    LoadExtension
  ...

── Bluebook ──
  Domain — Root of the domain model IR, holds aggregates and policies
    DefineDomain
    ValidateDomain
    GenerateCode
  Aggregate — DDD aggregate root with commands, events, and lifecycle
    AddAggregate
    AddAttribute
  ...

── Runtime ──
  Session — Application entry point, boots domain and wires ports
    Boot
    HandleCommand
  ...
```

## API

```ruby
# All domains in the bluebook (binding + chapters)
bluebook.all_domains
# => [#<Domain name="Binding">, #<Domain name="Bluebook">, ...]

# All commands across all chapters
bluebook.all_commands
# => [#<Command name="DefineDomain">, ...]

# All reactive policies across all chapters
bluebook.all_policies
# => [#<Policy name="AutoEvent">, ...]

# Find which chapter owns a command
bluebook.chapter_for_command("HandleCommand")
# => #<Domain name="Runtime">
```

## Adding descriptions

Descriptions flow into the glossary from the DSL `description` keyword
or inline aggregate definitions:

```ruby
aggregate "Pizza", "Composite menu item with toppings and price" do
  command "CreatePizza", "Add a new pizza to the menu" do
    attribute :name, String
  end
end
```
