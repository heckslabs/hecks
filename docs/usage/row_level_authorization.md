# Row-level Authorization

Row-level authorization restricts data access to individual records based on ownership
or tenancy. Hecks supports two modes:

1. **`owned_by :field`** on a gate — records are scoped to `Hecks.current_user`
2. **`tenancy: :row`** — records are scoped to `Hecks.tenant`

## Gate-based ownership (`owned_by`)

Declare `owned_by :owner_id` inside a gate block. `find` and `delete` raise
`Hecks::GateAccessDenied` when the record belongs to a different user. `all` and
`count` filter to only the current user's records.

```ruby
hecksagon = Hecks.hecksagon do
  gate "Order", :customer do
    allow :find, :all, :count, :create
    owned_by :owner_id   # attribute on the Order aggregate
  end
end

app = Hecks.load(domain, gate: :customer, hecksagon: hecksagon)

Hecks.current_user = "alice"
alice_order = Order.create(title: "My Order", owner_id: "alice")

Hecks.current_user = "bob"
Order.find(alice_order.id)  # => raises Hecks::GateAccessDenied
Order.all                   # => []  (bob has no orders)
```

## Current user context

Set the current user for the duration of a block:

```ruby
Hecks.with_user("alice") do
  Order.all   # alice's orders only
end
```

Or set it directly (thread-local):

```ruby
Hecks.current_user = "alice"
# ... do work ...
Hecks.current_user = nil
```

## Admin gate — full access

A gate without `owned_by` sees all records:

```ruby
hecksagon = Hecks.hecksagon do
  gate "Order", :admin do
    allow :find, :all, :count, :create, :destroy
  end
end

app = Hecks.load(domain, gate: :admin, hecksagon: hecksagon)

Hecks.current_user = "bob"
Order.find(alice_order.id)   # => works fine — admin has full access
```

## Row tenancy (`tenancy: :row`)

When the tenancy strategy is `:row`, all repositories are wrapped with ownership
scoping using `tenant_id` as the field and `Hecks.tenant` as the identity source:

```ruby
hecksagon = Hecks.hecksagon { tenancy :row }
app = Hecks.load(domain, hecksagon: hecksagon)

Hecks.tenant = "acme"
Invoice.create(amount: 100, tenant_id: "acme")

Hecks.tenant = "beta"
Invoice.all   # => []  — beta has no invoices
```

## Admin bypass

Load without a gate for unrestricted access:

```ruby
app = Hecks.load(domain)   # no gate: arg → full access
```
