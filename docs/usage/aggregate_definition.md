# Aggregate Definition

Attach a human-readable definition to any aggregate using the `definition:` keyword.
The definition is stored in the aggregate IR and surfaced by `Hecks.aggregates`.

## Usage

```ruby
Hecks.domain "Banking" do
  aggregate "Account", definition: "Manages customer funds and balances" do
    attribute :name, String
    attribute :balance, Float
    command("CreateAccount") { attribute :name, String }
  end

  aggregate "Loan", definition: "Tracks borrowed principal and repayment schedule" do
    attribute :principal, Float
    command("CreateLoan") { attribute :principal, Float }
  end
end
```

## Implicit PascalCase syntax

```ruby
Hecks.domain "Banking" do
  Account definition: "Manages customer funds and balances" do
    attribute :name, String
    command("CreateAccount") { attribute :name, String }
  end
end
```

## Inspector output

```ruby
Hecks.aggregates
# => ["Account (name: String, balance: Float) — Manages customer funds and balances",
#     "Loan (principal: Float) — Tracks borrowed principal and repayment schedule"]
```

## Positional description (legacy)

The positional argument still works for backward compatibility:

```ruby
aggregate "Account", "Manages customer funds" do
  # ...
end
```

When both are provided, `definition:` takes precedence.
