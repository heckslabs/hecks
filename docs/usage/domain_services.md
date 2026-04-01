# Domain Services

Domain services orchestrate operations that span multiple aggregates. Unlike commands, which operate on a single aggregate, services coordinate cross-aggregate workflows that don't naturally belong to any one aggregate.

## Defining a Service

Use the `service` keyword at the domain level:

```ruby
Hecks.domain "Banking" do
  aggregate "Account" do
    attribute :balance, Float

    command "Deposit" do
      attribute :account_id, String
      attribute :amount, Float
    end

    command "Withdraw" do
      attribute :account_id, String
      attribute :amount, Float
    end
  end

  service "TransferMoney" do
    attribute :source_id, String
    attribute :target_id, String
    attribute :amount, Float

    coordinates "Account"

    call do
      dispatch "Withdraw", account_id: source_id, amount: amount
      dispatch "Deposit",  account_id: target_id, amount: amount
    end
  end
end
```

## DSL Reference

Inside a `service` block:

| Method | Purpose |
|--------|---------|
| `attribute :name, Type` | Declare an input attribute |
| `coordinates "Agg1", "Agg2"` | Document which aggregates the service touches |
| `call { ... }` | The orchestration body -- dispatches commands |

The `call` block has access to all declared attributes as local methods and a `dispatch(command_name, **attrs)` helper that sends commands through the command bus.

## Runtime Usage

Services are wired as singleton methods on the domain module, using the underscored service name:

```ruby
app = Hecks.load(domain)

mod = Object.const_get("BankingDomain")
mod.transfer_money(source_id: source.id, target_id: target.id, amount: 250.0)
```

Each `dispatch` call within the service body publishes its own domain event, so a service that dispatches two commands produces two events.

## How It Works

1. `ServiceBuilder` collects attributes and the call body during DSL evaluation
2. The builder produces a `DomainModel::Behavior::Service` IR node
3. At runtime, `ServiceSetup.bind` wires each service as a method on the domain module
4. When invoked, a `ServiceContext` is created with the command bus and attribute values
5. The call body runs inside that context, with `dispatch` forwarding to the command bus

## When to Use Services vs. Policies

| Mechanism | Trigger | Use Case |
|-----------|---------|----------|
| **Service** | Explicit call | Orchestrate multiple commands in a defined sequence |
| **Policy** | Reactive (event) | React to one event by triggering another command |
| **Saga** | Long-running | Multi-step process with compensation on failure |

Services are synchronous and caller-initiated. Policies are asynchronous and event-driven. Use a service when you need to guarantee ordering and collect results from multiple commands in one call.
