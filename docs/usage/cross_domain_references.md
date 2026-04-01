# Cross-Domain Qualified References

Reference aggregates in other bounded contexts using the `Domain::Aggregate` syntax.

## DSL

```ruby
Hecks.domain "Shipping" do
  aggregate "Shipment" do
    attribute :address, String
    reference_to "Billing::Invoice"

    command "CreateShipment" do
      attribute :address, String
      reference_to "Billing::Invoice"
    end
  end
end

Hecks.domain "Billing" do
  aggregate "Invoice" do
    attribute :total, Integer
    command "CreateInvoice" do
      attribute :total, Integer
    end
  end
end
```

## How it works

1. **Compile time** -- qualified references (where the type contains `::`) are
   exempt from single-domain validation. They cannot be checked until all
   domains are loaded.

2. **Boot time** -- `MultiDomain::Validator` verifies the target domain is
   loaded. If you reference `Billing::Invoice` but the Billing domain is not
   present, boot fails with a clear error.

3. **Runtime** -- IDOR reference validation resolves cross-domain references
   from the foreign domain's constant (`BillingDomain::Invoice`). Existence
   checks and authorizer hooks work identically to same-domain references.

## Unqualified references are rejected

If an unqualified `reference_to "Invoice"` happens to match an aggregate in
another loaded domain, the validator rejects it and suggests the qualified form:

```
Qualify the reference: reference_to "Billing::Invoice"
```

## Opting out of runtime validation

Use `validate: false` on the command reference for eventual consistency:

```ruby
command "CreateShipment" do
  reference_to "Billing::Invoice", validate: false
end
```

## IR

```ruby
ref = domain.aggregates.first.references.first
ref.domain        # => "Billing"
ref.type          # => "Invoice"
ref.kind          # => :cross_context
ref.cross_context? # => true
```
