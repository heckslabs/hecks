# Chapter CLI Generator

Generate Thor command-line interfaces directly from Bluebook chapter definitions.
Every aggregate's commands become CLI verbs with typed `--flag` options.

## Quick start

```ruby
require "hecks"
Kernel.load("HecksBluebook")
require "hecks/generators/cli_generator"

domain = Hecks::Chapters::Bluebook.definition
gen = Hecks::Generators::CliGenerator.new(domain)

# Generate source code
puts gen.generate

# Or build a live Thor class and run it
cli = gen.build_thor_class
cli.start(["help"])
cli.start(["define_domain", "--name", "Pizzas", "--version", "1.0"])
```

## How it works

The generator walks a chapter's domain IR:

- **Aggregate name** provides context for grouping
- **Command name** becomes the CLI verb (snake_cased: `CreatePizza` -> `create_pizza`)
- **Command attributes** become `--flag` options with Thor types
- **Aggregate description** becomes help text

When multiple commands across different aggregates share the same verb,
the generator automatically prefixes with the aggregate name to avoid
collisions (e.g., `domain_compiler_compile` vs `validator_compile`).

## Type mapping

| IR Type    | Thor Type  |
|------------|------------|
| String     | `:string`  |
| Integer    | `:numeric` |
| Float      | `:numeric` |
| Boolean    | `:boolean` |
| Array      | `:array`   |
| Hash, JSON | `:hash`    |
| Date       | `:string`  |

## Namespaced output

Wrap the generated class in a module:

```ruby
gen = Hecks::Generators::CliGenerator.new(domain, namespace: "MyApp")
puts gen.generate
# =>
# module MyApp
#   class BluebookCLI < Thor
#     ...
#   end
# end
```

## Works with any chapter

```ruby
cli_domain = Hecks::Chapters::Cli.definition
gen = Hecks::Generators::CliGenerator.new(cli_domain)
cli = gen.build_thor_class
cli.start(ARGV)
```
