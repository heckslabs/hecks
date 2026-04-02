# Universal `description` Keyword

Every DSL block in Hecks supports a `description` method that attaches
human-readable text to the IR node. Descriptions feed the domain glossary,
generated documentation, MCP tool context, and LLM prompts.

## Usage

```ruby
Hecks.domain "Banking" do
  description "Core banking operations for retail customers"

  aggregate "Account" do
    description "Manages customer funds and balances"
    attribute :name, String
    attribute :balance, Float

    value_object "Address" do
      description "Mailing address for account statements"
      attribute :street, String
      attribute :city, String
    end

    entity "LedgerEntry" do
      description "Records a single financial transaction"
      attribute :amount, Float
    end

    command "OpenAccount" do
      description "Opens a new bank account for a customer"
      attribute :name, String
    end

    event "AccountOverdrawn" do
      description "Emitted when balance goes negative"
      attribute :amount, Float
    end

    policy "FraudAlert" do
      description "Flags large withdrawals for review"
      on "OpenedAccount"
      trigger "FlagSuspicious"
    end
  end

  service "TransferMoney" do
    description "Moves funds between two accounts"
    attribute :amount, Float
  end

  workflow "LoanApproval" do
    description "Multi-step loan evaluation process"
    step "ScoreLoan"
  end

  view "AccountBalance" do
    description "Running balance projection"
    project("OpenedAccount") { |event, state| state }
  end
end
```

## Accessing descriptions from the IR

```ruby
domain = Hecks.domain("Banking") { ... }

domain.description
# => "Core banking operations for retail customers"

domain.aggregates.first.description
# => "Manages customer funds and balances"

domain.aggregates.first.commands.first.description
# => "Opens a new bank account for a customer"
```

## DslSerializer round-trip

Descriptions are preserved when serializing a domain back to DSL source:

```ruby
source = Hecks::DslSerializer.new(domain).serialize
restored = eval(source)
restored.aggregates.first.description
# => "Manages customer funds and balances"
```

## Supported blocks

| DSL block        | IR node                          |
|------------------|----------------------------------|
| `domain`         | `DomainModel::Structure::Domain` |
| `aggregate`      | `DomainModel::Structure::Aggregate` |
| `command`        | `DomainModel::Behavior::Command` |
| `event`          | `DomainModel::Behavior::DomainEvent` |
| `value_object`   | `DomainModel::Structure::ValueObject` |
| `entity`         | `DomainModel::Structure::Entity` |
| `policy`         | `DomainModel::Behavior::Policy` |
| `service`        | `DomainModel::Behavior::Service` |
| `workflow`       | `DomainModel::Behavior::Workflow` |
| `view`           | `DomainModel::Behavior::ReadModel` |
| `lifecycle`      | `DomainModel::Structure::Lifecycle` |
