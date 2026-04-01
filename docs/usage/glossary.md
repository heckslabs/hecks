# Glossary — Ubiquitous Language

Define and enforce domain terminology with the `glossary` DSL block.

## DSL

```ruby
Hecks.domain "Billing" do
  glossary do
    # Define a term with a definition
    define "invoice", as: "A formal request for payment issued to a customer"

    # Prefer a term over banned synonyms, with an optional definition
    prefer "customer", not: ["user", "client"],
      definition: "The party responsible for payment"

    # Prefer without a definition — just enforces naming
    prefer "line item", not: ["row", "entry"]
  end

  aggregate "Invoice" do
    attribute :total, Float
    command "CreateInvoice" do
      attribute :total, Float
    end
  end
end
```

## CLI

```bash
# Print glossary to stdout
hecks glossary

# Print glossary for a specific domain
hecks glossary --domain path/to/domain

# Export to glossary.md
hecks glossary --export
```

## Generated Output

The glossary `generate` method produces markdown including an
"Ubiquitous Language" section:

```
## Ubiquitous Language

- **invoice** -- A formal request for payment issued to a customer
- **customer** -- The party responsible for payment (avoid: user, client)
- **line item** (avoid: row, entry)
```

## Strict Mode

Use `glossary(strict: true)` to turn glossary violations into errors
(instead of warnings) during `hecks validate`.

```ruby
glossary(strict: true) do
  prefer "stakeholder", not: ["user", "person"]
end
```
