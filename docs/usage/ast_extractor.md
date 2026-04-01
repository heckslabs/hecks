# AST-Based Domain Extraction

Extract domain structure from Bluebook files without eval, using Ruby's
built-in `RubyVM::AbstractSyntaxTree` parser. Ideal for static analysis,
linting, and tooling that needs to read domain definitions safely.

## Quick Start

```ruby
require "hecks"

# From a source string
result = Hecks::AstExtractor.extract('Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String
    command "CreatePizza" do
      attribute :name, String
    end
  end
end')

result[:name]                          # => "Pizzas"
result[:aggregates].first[:name]       # => "Pizza"
result[:aggregates].first[:commands]   # => [{ name: "CreatePizza", ... }]
```

## From a File

```ruby
result = Hecks::AstExtractor.extract_file("examples/pizzas/PizzasBluebook")
result[:name]        # => "Pizzas"
result[:aggregates]  # => [{ name: "Pizza", ... }, { name: "Order", ... }]
```

## What Gets Extracted

The extractor returns a plain Ruby hash with these keys:

| Key               | Type            | Description                          |
|-------------------|-----------------|--------------------------------------|
| `:name`           | String          | Domain name                          |
| `:aggregates`     | Array of Hash   | Aggregate definitions                |
| `:policies`       | Array of Hash   | Domain-level reactive policies       |
| `:services`       | Array of Hash   | Domain services                      |
| `:views`          | Array of Hash   | Read model view definitions          |
| `:workflows`      | Array of Hash   | Workflow definitions                 |
| `:world_goals`    | Array of Symbol | Declared world goals                 |
| `:actors`         | Array of Hash   | Actor definitions                    |
| `:sagas`          | Array of Hash   | Saga definitions                     |
| `:modules`        | Array of Hash   | Domain module groupings              |

Each aggregate hash contains:

| Key               | Type          | Description                            |
|-------------------|---------------|----------------------------------------|
| `:name`           | String        | Aggregate name                         |
| `:attributes`     | Array of Hash | `{ name:, type:, list:, default: }`    |
| `:commands`       | Array of Hash | `{ name:, attributes:, references: }`  |
| `:value_objects`  | Array of Hash | `{ name:, attributes:, invariants: }`  |
| `:entities`       | Array of Hash | `{ name:, attributes:, invariants: }`  |
| `:policies`       | Array of Hash | `{ name:, event_name:, trigger_command:, async: }` |
| `:validations`    | Array of Hash | `{ field:, rules: }`                   |
| `:specifications` | Array of Hash | `{ name: }`                            |
| `:references`     | Array of Hash | `{ type:, domain:, role:, validate: }` |
| `:queries`        | Array of Hash | `{ name: }`                            |
| `:invariants`     | Array of Hash | `{ message: }`                         |
| `:scopes`         | Array of Hash | `{ name:, conditions: }`               |

## Banking Example

```ruby
result = Hecks::AstExtractor.extract_file("examples/banking/BankingBluebook")

# Domain-level policies with attribute mapping
result[:policies].first
# => { name: "DisburseFunds",
#      event_name: "IssuedLoan",
#      trigger_command: "Deposit",
#      async: false,
#      attribute_map: { account_id: :account_id, principal: :amount } }

# Specifications (name only -- blocks are not evaluable without eval)
loan = result[:aggregates].find { |a| a[:name] == "Loan" }
loan[:specifications]  # => [{ name: "HighRisk" }]

# Entities
account = result[:aggregates].find { |a| a[:name] == "Account" }
account[:entities].first[:name]  # => "LedgerEntry"
```

## Comparison with DSL Eval

| Feature              | `Hecks.domain` (eval) | `AstExtractor` (AST) |
|----------------------|-----------------------|-----------------------|
| Executes code        | Yes                   | No                    |
| Returns Domain IR    | Yes (full objects)    | Hash (lightweight)    |
| Proc/block capture   | Yes                   | No (name only)        |
| Safe for untrusted   | No                    | Yes                   |
| Speed                | Fast                  | Fast                  |

The AST extractor captures everything about the domain *structure* but
not executable blocks (invariant bodies, specification predicates,
command handlers). Use it when you need to inspect or analyze domain
definitions without running them.
