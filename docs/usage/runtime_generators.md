# Runtime Code Generation

Generate Ruby runtime wiring modules from Bluebook IR. Instead of
hand-writing orchestration loops that iterate domain metadata at boot
time, these generators produce explicit, unrolled Ruby code.

## Generators

| Generator                    | Method generated       | What it wires                        |
|------------------------------|------------------------|--------------------------------------|
| RepositoryWiringGenerator    | setup_repositories     | Per-aggregate repo instantiation     |
| PortWiringGenerator          | wire_ports!            | Persistence/Commands/Querying.bind   |
| SubscriberWiringGenerator    | setup_subscribers      | Event bus subscriptions              |
| PolicyWiringGenerator        | setup_policies         | Reactive policy subscriptions        |
| ServiceWiringGenerator       | setup_services         | Singleton method definitions         |
| WorkflowWiringGenerator      | setup_workflows        | Workflow executor methods            |
| SagaWiringGenerator          | setup_sagas            | Saga runner methods                  |

## Usage

```ruby
require "hecks"

# Load a domain definition
domain = Hecks::Chapters::Bluebook.definition

# Generate all wiring files
gen = Hecks::Generators::Infrastructure::RuntimeGenerator.new(domain, domain_module: "PizzasDomain")
files = gen.generate  # => Hash of { filename => Ruby source }

files.each do |name, source|
  puts "--- #{name} ---"
  puts source
end
```

## Individual generators

```ruby
# Generate just repository wiring
gen = Hecks::Generators::Infrastructure::RepositoryWiringGenerator.new(
  domain,
  domain_module: "PizzasDomain"
)
puts gen.generate  # => Ruby source string
```

## Verification

Generator output is verified as Phase 4 of `bin/verify`:

```
$ bin/verify --format documentation
```

Each generator is checked for valid Ruby syntax and correct module/method names.
