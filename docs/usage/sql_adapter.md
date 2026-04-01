# SQL Adapter Lifecycle

One line from domain definition to SQL-backed persistence.

## Usage

```ruby
require "hecks"

# In-memory SQLite (great for development)
app = Hecks.boot(__dir__, adapter: :sqlite)

# File-based SQLite
app = Hecks.boot(__dir__, adapter: { type: :sqlite, database: "banking.db" })

# PostgreSQL (future)
app = Hecks.boot(__dir__, adapter: { type: :postgres, host: "localhost", database: "banking" })
```

## What it does

`Hecks.boot` with an adapter option:
1. Requires Sequel
2. Creates the database connection
3. Generates SQL repository classes for each aggregate
4. Creates tables from the domain IR (columns, types, join tables)
5. Wires everything into a Runtime

## Before and after

```ruby
# Before (30+ lines):
require "sequel"
db = Sequel.sqlite
db.create_table(:accounts) { String :id, primary_key: true; Float :balance; ... }
# ... repeat for every aggregate ...
gen = Hecks::Generators::SQL::SqlAdapterGenerator.new(agg, domain_module: mod)
eval(gen.generate, TOPLEVEL_BINDING)
# ... repeat for every aggregate ...
app = Hecks::Services::Runtime.new(domain) do
  adapter "Account", AccountSqlRepository.new(db)
  # ... repeat ...
end

# After (1 line):
app = Hecks.boot(__dir__, adapter: :sqlite)
```

## Example

```ruby
require "hecks"
app = Hecks.boot(__dir__, adapter: :sqlite)

Customer.register(name: "Alice", email: "alice@example.com")
Account.open(customer_id: alice.id, account_type: "checking", daily_limit: 5000.0)
Account.deposit(account_id: acct.id, amount: 1000.0)

# Data persists in SQL
Account.count  # => 1
Account.find(acct.id).balance  # => 1000.0
```
