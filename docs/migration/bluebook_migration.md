# Bluebook Migration Guide

Migrate from separate multi-domain files to the Bluebook/Chapter pattern.

## Toggle System

Each module has an independent toggle in `Hecks::BluebookToggles`. Enable
toggles incrementally — any combination keeps the system running.

```ruby
Hecks::BluebookToggles.enable(:dsl, :ir)        # just DSL + IR
Hecks::BluebookToggles.enable(:runtime)          # add runtime support
Hecks::BluebookToggles.all_enabled?              # => false (more toggles remain)
```

### Available Toggles

| Toggle | What it enables | Old path (still works) |
|--------|----------------|----------------------|
| `:dsl` | `Hecks.bluebook` method | `Hecks.domain` per file |
| `:ir` | `Structure::BluebookStructure` IR node | Separate `Structure::Domain` per file |
| `:runtime` | `Hecks.open(bluebook)` | `Hecks.boot` with `hecks_domains/` dir |
| `:boot` | `Hecks.boot` detects Bluebook files | `Hecks.boot` detects `*Bluebook` files per domain |
| `:workshop` | Workshop `chapter` mode | Workshop single-domain mode |
| `:configure` | `Hecks.configure { chapter "x" }` | `Hecks.configure { domain "x" }` |
| `:cli` | CLI uses chapter terminology | CLI uses domain terminology |
| `:examples` | Examples use Bluebook/Chapter | Examples use separate domain files |

## Step-by-Step Migration

### Step 1: Combine domain files into a single Bluebook

**Before** (separate files in `bluebook/`):
```
bluebook/PizzasBluebook
bluebook/BillingBluebook
bluebook/ShippingBluebook
```

Each containing `Hecks.domain "X" do ... end`.

**After** (single Bluebook file):
```ruby
# AppBluebook
Hecks.bluebook "PizzaShop" do
  chapter "Pizzas" do
    # contents of PizzasBluebook
  end

  chapter "Billing" do
    # contents of BillingBluebook
  end

  chapter "Shipping" do
    # contents of ShippingBluebook
  end
end
```

### Step 2: Switch boot call

**Before:**
```ruby
apps = Hecks.boot(__dir__)  # detects bluebook/ with multiple files
```

**After:**
```ruby
# Option A: use Hecks.open directly
book = Hecks.bluebook("PizzaShop") { ... }
runtimes = Hecks.open(book)

# Option B: let Hecks.boot auto-detect (with :boot toggle enabled)
runtimes = Hecks.boot(__dir__)  # detects AppBluebook using Hecks.bluebook
```

### Step 3: Update Hecks.configure (if used)

**Before:**
```ruby
Hecks.configure do
  domain "pizzas_domain"
  domain "billing_domain" do
    listens_to "pizzas_domain"
  end
end
```

**After:**
```ruby
Hecks.configure do
  chapter "pizzas_domain"
  chapter "billing_domain" do
    listens_to "pizzas_domain"
  end
end
```

### Step 4: Update Workshop usage

**Before:**
```ruby
# Separate workshops per domain
pizzas = Hecks.workshop("Pizzas")
billing = Hecks.workshop("Billing")
```

**After:**
```ruby
# Single workshop with chapters
shop = Hecks.workshop("PizzaShop")
shop.chapter("Pizzas") { aggregate("Pizza") { ... } }
shop.chapter("Billing") { aggregate("Invoice") { ... } }
shop.play!  # boots all chapters together
```

## Cleanup (Phase 7)

Once all toggles are enabled and stable:

1. Enable all toggles: `Hecks::BluebookToggles.enable(*Hecks::BluebookToggles::MODULES.keys)`
2. Verify all tests pass
3. Remove `BluebookToggles` module and all toggle checks
4. Delete old multi-file domain detection in `Boot#find_domains_dir`
5. Remove `Configuration#domain` (keep only `chapter`)
6. Delete separate `*Bluebook` files, keep single Bluebook file per app

## Terminology Map

| Old term | New term |
|----------|----------|
| Domain | Chapter |
| Multi-domain | Bluebook |
| `Hecks.domain` | `chapter` (inside `Hecks.bluebook`) |
| `hecks_domains/` directory | Single `*Bluebook` file |
| `Hecks.configure { domain }` | `Hecks.configure { chapter }` |
