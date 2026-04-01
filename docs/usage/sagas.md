# Sagas / Process Managers

Long-running stateful business processes with compensation.

## DSL

```ruby
Hecks.domain "Orders" do
  aggregate "Order" do
    attribute :item, String
    attribute :status, String

    command "ReserveInventory" do
      attribute :item, String
    end

    command "ChargePayment" do
      attribute :item, String
    end

    command "ReleaseInventory" do
      attribute :item, String
    end

    command "RefundPayment" do
      attribute :item, String
    end

    command "CancelOrder" do
      attribute :item, String
    end
  end

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
