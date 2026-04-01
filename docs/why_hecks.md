# Why Hecks instead of ActiveRecord?

ActiveRecord makes the database the center of your app. Hecks makes your business logic the center. Your model layer shouldn't be a tangle of persistence logic, callbacks, and query scopes with business rules buried somewhere in the middle. Describing your business shouldn't be harder than `rails generate model` — so it isn't.

## Model real-world relationships, not database tables

ActiveRecord starts with the database and works backward — your models are table wrappers. Hecks starts with how your business actually works. A Pizza has Toppings. An Order references a Pizza. Describe that in Ruby, and the database plumbing is handled for you.

## Your business logic is a gem, not a directory

Hecks generates a standalone Ruby gem with zero dependencies. Your domain is a versioned artifact — share it across multiple apps, test it in isolation, reason about it without a database running.

## No persistence in your objects

A Hecks class is just Ruby — attributes, requirements, and rules. No `belongs_to`, no `has_many`, no callbacks, no `before_save`. Database plumbing doesn't belong in your business logic.

## Tests don't need a database

Code runs against memory by default — no migrations, no fixtures, no database process. Production uses SQL. The code is identical either way.

## Lookups are part of your business

Instead of scattering `where` clauses across controllers and services, define named lookups in the DSL:

```ruby
aggregate "Order" do
  query "Pending" do
    where(status: "pending")
  end

  query "ForPizza" do |pizza_id|
    where(pizza_id: pizza_id)
  end
end
```

`Order.pending` and `Order.for_pizza(id)` are part of your domain language, not ad-hoc SQL. ActiveRecord-style queries (`where`, `order`, `limit`) are available as an opt-in for when you need them:

```ruby
Hecks.configure do
  domain "pizzas_domain"
  include_ad_hoc_queries  # enables Pizza.where(...).order(...).limit(...)
end
```

## Commands make intent explicit

Instead of `pizza.update(status: "cancelled")`, define `CancelOrder` — a named command that fires a `CancelledOrder` event. Every state change has a name, a payload, and a paper trail.

## Any database, zero lock-in

Configure your database in one line. Sequel handles MySQL, Postgres, and SQLite:

```ruby
Hecks.configure do
  domain "pizzas_domain"
  adapter :sql, database: :mysql,
    host: "localhost", user: "root", password: "secret", name: "pizzas"
end
```

Switch databases by changing the config. Domain code never touches SQL.

## Still feels like ActiveRecord when you want it to

With `include_ad_hoc_queries`, you get the familiar API:

```ruby
Pizza.where(style: "Classic").order(:name).limit(5)
Pizza.find_by(name: "Margherita")
Pizza.order(name: :desc).offset(10)
Pizza.where(price: gt(10))
pizza.save
pizza.update(name: "New")
pizza.destroy
```

No excuses.

## Event sourcing built in

Add `event_sourced: true` and every command records its event. Full audit trail, no extra code:

```ruby
adapter :sql, database: :postgres, event_sourced: true
```

```ruby
Pizza.create(name: "Margherita")
Pizza.history(pizza.id)  # => full event stream
```

Try that with ActiveRecord.

---

Even simple CRUD apps have a domain. Hecks makes you model it first and pick a database second — instead of the other way around.
