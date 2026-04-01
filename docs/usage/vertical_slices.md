# Vertical Slice Architecture

Extract vertical slices from domain reactive chains. A slice is everything triggered by a single command: the command, its event, any policies it fires, and all downstream commands.

## Setup

```ruby
require "hecks"
require "hecks_features"
```

## Extract slices

```ruby
domain = Hecks.domain("Banking") do
  aggregate "Loan" do
    attribute :principal, Float
    command("IssueLoan") { attribute :principal, Float }
    command("DefaultLoan") { attribute :loan_id, String }
  end

  aggregate "Account" do
    attribute :balance, Float
    command("Deposit") { attribute :amount, Float }
  end

  aggregate "Customer" do
    attribute :name, String
    command("SuspendCustomer") { attribute :customer_id, String }
  end

  policy "DisburseFunds" do
    on "IssuedLoan"
    trigger "Deposit"
  end

  policy "SuspendOnDefault" do
    on "DefaultedLoan"
    trigger "SuspendCustomer"
  end
end

domain.slices.each do |slice|
  puts "#{slice.name} (#{slice.aggregates.join(', ')})"
  puts "  Commands: #{slice.commands.join(' -> ')}"
  puts "  Cross-aggregate: #{slice.cross_aggregate?}"
end
# Issue Loan -> Deposit (Loan, Account)
#   Commands: IssueLoan -> Deposit
#   Cross-aggregate: true
# Default Loan -> Suspend Customer (Loan, Customer)
#   Commands: DefaultLoan -> SuspendCustomer
#   Cross-aggregate: true
```

## Generate a Mermaid diagram

```ruby
puts domain.slices_diagram
# flowchart LR
#   subgraph slice0["Issue Loan -> Deposit"]
#     s0_0[IssueLoan]
#     s0_0_evt([IssuedLoan])
#     s0_0 --> s0_0_evt
#     s0_1{{DisburseFunds}}
#     s0_0_evt -.-> s0_1
#     ...
#   end
```

## Leaky slice detection

If an aggregate-scoped policy triggers a command on a different aggregate,
validation warns you to move it to a domain-level policy:

```ruby
# This is "leaky" — cross-aggregate coupling hidden inside Order
aggregate "Order" do
  policy "ChargePayment" do
    on "PlacedOrder"
    trigger "ChargeCard"  # belongs to Payment aggregate
  end
end

# Fix: promote to domain-level policy for visibility
policy "ChargePayment" do
  on "PlacedOrder"
  trigger "ChargeCard"
end
```
