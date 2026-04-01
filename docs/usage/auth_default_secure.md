# Auth Default-Secure

When a domain declares `actor` requirements on commands, Hecks now
raises `ConfigurationError` at boot if no `:auth` extension is
registered. This prevents silent security gaps where access control
is defined in the DSL but never enforced at runtime.

## The problem

```ruby
Hecks.domain "Invoicing" do
  aggregate "Invoice" do
    attribute :total, Float
    command "Approve" do
      actor "Manager"       # declares who may approve
      attribute :invoice_id, String
    end
  end
end

app = Hecks.boot(__dir__)   # no :auth extension loaded
Invoice.approve(invoice_id: "123")  # silently succeeds — oops!
```

## The fix

The boot process now checks for actor-protected commands after
extensions are wired. If any exist and no `:auth` middleware is
registered, it raises:

```
Hecks::ConfigurationError:
  Domain 'Invoicing' declares actor requirements on 1 command
  (Approve) but no auth middleware is registered. Add `extend :auth`
  to your Hecks.boot or Hecks.configure block, or explicitly opt out
  with `extend :auth, enforce: false`.
```

## Adding auth

```ruby
app = Hecks.boot(__dir__)
app.extend(:auth)  # wires actor-based authorization middleware
```

## Opting out explicitly

If you intentionally want to skip authorization (e.g., in a dev
environment or a batch-processing service), use `enforce: false`:

```ruby
app = Hecks.boot(__dir__)
app.extend(:auth, enforce: false)  # registers a no-op sentinel
```

This documents the intentional decision and satisfies the boot check
without enforcing any access control.

## When does the check run?

- After `Hecks.boot` fires all extensions
- After `Hecks.configure` boots domains (via `fire_extensions`)
- Not after `Hecks.load` (test helper) — call `app.check_auth_coverage!`
  manually if you want the check in tests
