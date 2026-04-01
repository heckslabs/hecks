# Sagas / Process Managers

A saga coordinates a long-running process that spans multiple aggregates and commands. Use sagas when a single business operation requires several sequential steps — and each step may need to be undone if a later step fails.

## When to use a saga vs. a workflow

| Use a **saga** when... | Use a **workflow** when... |
|---|---|
| Steps can fail and must be compensated | Steps always succeed or just branch |
| You need explicit rollback commands | You need specification-based branching |
| Coordinating across aggregates with side effects | Orchestrating a single aggregate's lifecycle |

## DSL

Sagas are declared at the domain level, outside any aggregate block:

```ruby
Hecks.domain "Fulfillment" do
  aggregate "Order" do ... end
  aggregate "Inventory" do ... end
  aggregate "Payment" do ... end

  saga "OrderFulfillment" do
    step "ReserveInventory", on_success: "ChargePayment", on_failure: "CancelOrder"
    step "ChargePayment",    on_success: "ShipOrder",     on_failure: "RefundReservation"
    step "ShipOrder"
    compensation "ReleaseInventory"
    compensation "RefundPayment"
  end
end
```

### step

```ruby
step "CommandName", on_success: "NextCommand", on_failure: "RollbackCommand"
```

- `on_success:` — the command to trigger when this step completes successfully
- `on_failure:` — the command to trigger when this step raises an error

Both options are optional. A step without `on_success` is the terminal step.

You can also use the block form with `compensate` per step and timeout metadata:

```ruby
saga "OrderFulfillment" do
  step "ReserveInventory" do
    on_success "InventoryReserved"
    on_failure "ReservationFailed"
    compensate "ReleaseInventory"
  end
  step "ChargePayment" do
    on_success "PaymentCharged"
    on_failure "PaymentFailed"
    compensate "RefundPayment"
  end
  timeout "48h"
  on_timeout "CancelOrder"
end
```

### compensation

```ruby
compensation "CommandName"
```

Registers a rollback command. Compensations are collected in declaration order and run in reverse if the saga must unwind. Each compensation should undo the effects of its corresponding step.

## Example: Order Fulfillment

```ruby
Hecks.domain "Ecommerce" do
  aggregate "Order" do
    attribute :customer_id, String
    attribute :total, Float
    command "PlaceOrder" do
      attribute :customer_id, String
      attribute :total, Float
    end
    command "CancelOrder" do
      reference_to "Order"
    end
    command "ShipOrder" do
      reference_to "Order"
    end
  end

  aggregate "Inventory" do
    command "ReserveInventory" do
      reference_to "Order"
    end
    command "ReleaseInventory" do
      reference_to "Order"
    end
  end

  aggregate "Payment" do
    command "ChargePayment" do
      reference_to "Order"
    end
    command "RefundPayment" do
      reference_to "Order"
    end
    command "RefundReservation" do
      reference_to "Order"
    end
  end

  saga "OrderFulfillment" do
    step "ReserveInventory", on_success: "ChargePayment", on_failure: "CancelOrder"
    step "ChargePayment",    on_success: "ShipOrder",     on_failure: "RefundReservation"
    step "ShipOrder"
    compensation "ReleaseInventory"
    compensation "RefundPayment"
  end
end
```

## Running a saga

```ruby
app = Hecks.load(domain)

result = OrdersDomain.start_order_fulfillment(item: "Widget")
result[:state]           # => :completed
result[:saga_id]         # => "saga_abc123..."
result[:completed_steps] # => [0, 1]
```

## Compensation

When a step fails, all previously completed steps are compensated in reverse order.
Each step's `compensate` command is dispatched best-effort (failures logged, not re-raised).

```ruby
# If ChargePayment fails, ReleaseInventory is dispatched automatically
result[:state] # => :failed
result[:error] # => "ChargePayment: Payment gateway unavailable"
```

## State machine

```
pending -> running -> completed
                   -> compensating -> failed
```

## Simple keyword syntax

For steps without compensation blocks:

```ruby
saga "SimpleProcess" do
  step "StepOne", on_success: "StepOneDone"
  step "StepTwo", on_success: "StepTwoDone"
end
```

## Saga store

The default in-memory store is swappable. The store persists saga instance state
keyed by `saga_id` with `save`, `find`, `delete`, and `clear` methods.

## Inspecting sagas in the domain IR

Saga definitions are stored in the domain IR and available after compilation:

```ruby
app = Hecks.boot(__dir__)
saga = app.domain.sagas.find { |s| s[:name] == "OrderFulfillment" }

saga[:steps].each do |s|
  puts "#{s[:command]} -> success: #{s[:on_success]} | fail: #{s[:on_failure]}"
end
# ReserveInventory -> success: ChargePayment | fail: CancelOrder
# ChargePayment -> success: ShipOrder | fail: RefundReservation
# ShipOrder -> success:  | fail:

saga[:compensations]
# => ["ReleaseInventory", "RefundPayment"]
```
