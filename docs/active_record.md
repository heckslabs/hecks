# Hecks for ActiveRecord Users

You know ActiveRecord. Here's how Hecks compares.

## The familiar stuff

```ruby
# ActiveRecord                    # Hecks
Pizza.create(name: "Margherita")  Pizza.create(name: "Margherita")
Pizza.find(id)                    Pizza.find(id)
Pizza.all                         Pizza.all
Pizza.count                       Pizza.count
Pizza.first                       Pizza.first
Pizza.last                        Pizza.last
pizza.update(name: "New")         pizza.update(name: "New")
pizza.save                        pizza.save
pizza.destroy                     pizza.destroy
pizza.destroyed?                  pizza.destroyed?
```

Same API. Different engine.

## Where they diverge

### Queries

ActiveRecord scatters queries everywhere:
```ruby
# ActiveRecord — queries in controllers, services, everywhere
Pizza.where(style: "Classic").order(:name).limit(5)
```

Hecks encourages named queries in the DSL:
```ruby
# Hecks — queries are part of your domain description
query "ByDescription" do |desc|
  where(description: desc)
end

# Then use them as class methods
Pizza.by_description("Classic")
```

Want the ActiveRecord-style ad hoc queries too? Opt in:
```ruby
Hecks.configure do
  domain "pizzas_domain"
  include_ad_hoc_queries  # now Pizza.where(...).order(...) works
end
```

### Callbacks → Commands + Policies

ActiveRecord:
```ruby
class Order < ApplicationRecord
  after_create :reserve_stock
  after_create :send_notification
  before_save :validate_quantity
end
```

Hecks:
```ruby
aggregate "Order" do
  attribute :pizza_id, reference_to("Pizza")
  attribute :quantity, Integer

  command "PlaceOrder" do
    attribute :pizza_id, reference_to("Pizza")
    attribute :quantity, Integer
  end

  command "ReserveStock" do
    attribute :pizza_id, reference_to("Pizza")
    attribute :quantity, Integer
  end

  # When an order is placed, automatically reserve stock
  policy "ReserveIngredients" do
    on "PlacedOrder"
    trigger "ReserveStock"
  end
end
```

No hidden callbacks. Every cause and effect is visible in the DSL. Reactive policies
listen for events and trigger commands. Guard policies validate commands with a block.

### Associations → References + Value Objects

ActiveRecord:
```ruby
class Pizza < ApplicationRecord
  has_many :toppings
  belongs_to :restaurant
end
```

Hecks:
```ruby
aggregate "Pizza" do
  attribute :restaurant_id, reference_to("Restaurant")
  attribute :toppings, list_of("Topping")

  value_object "Topping" do
    attribute :name, String
    attribute :amount, Integer
  end
end
```

References are by ID (not objects). Toppings are embedded value objects that live
inside the Pizza — accessed via collection proxies:

```ruby
pizza.toppings.create(name: "Mozzarella", amount: 2)
pizza.toppings.each { |t| puts t.name }
pizza.toppings.count
```

### Validations

ActiveRecord:
```ruby
class Pizza < ApplicationRecord
  validates :name, presence: true
end
```

Hecks:
```ruby
aggregate "Pizza" do
  attribute :name, String
  validation :name, presence: true
end
```

In plain Ruby, validations are enforced at construction time. In Rails, Hecks
converts DSL validations to ActiveModel validators so `pizza.valid?` and
`pizza.errors` work as expected in forms.

### Migrations

ActiveRecord:
```bash
rails generate migration CreatePizzas name:string style:string
rake db:migrate
```

Hecks (standalone):
```bash
hecks generate:migrations
hecks db:migrate --database my.db
```

Hecks (in Rails):
```bash
rails generate active_hecks:migration
rake hecks:db:migrate
```

Hecks diffs your DSL against a saved snapshot and auto-generates SQL migrations.
No manual column definitions — add an attribute to the DSL and the migration appears.

### Testing

ActiveRecord:
```ruby
# Need database, fixtures, seeds, cleanup
let(:pizza) { Pizza.create!(name: "Test") }
```

Hecks:
```ruby
# No database needed — memory adapters by default
app = Hecks::Services::Application.new(domain)
Pizza.create(name: "Test")
```

Tests run against in-memory adapters. No database process, no migrations, no fixtures.

## The big differences

| | ActiveRecord | Hecks |
|---|---|---|
| **Your model is** | A database table wrapper | A pure Ruby class |
| **Persistence** | Baked into every object | Plugged in from outside |
| **Business rules** | Mixed with callbacks and validations | In the DSL, enforced at build time |
| **Database** | One database, configured in database.yml | Any Sequel-compatible database |
| **Testing** | Needs database | Runs in memory |
| **Sharing** | Copy model files between apps | Publish a gem, add to Gemfile |
| **Events** | Roll your own or add a gem | Built in, automatic |
| **Multiple domains** | One app, one set of models | Multiple domain gems in one app |

## Switching from ActiveRecord

1. Describe your models in a `hecks_domain.rb` file
2. Run `hecks build` to generate the domain gem
3. Add the gem to your Rails Gemfile
4. Run `rails generate active_hecks:init` to create the initializer, or add
   `config/initializers/hecks.rb` manually:

```ruby
Hecks.configure do
  domain "your_domain"
  adapter :sql                    # auto-detects from Rails database.yml
  include_ad_hoc_queries          # familiar where/order/limit API
end
```

5. Your controllers don't change — `Pizza.create`, `Pizza.find`, `Pizza.all` all work
6. Generate migrations when the domain changes: `rails generate active_hecks:migration`
