# MongoDB Persistence Adapter

Store aggregates as MongoDB documents instead of in-memory hashes or SQL rows.

## Setup

Add the mongo gem to your Gemfile:

```ruby
gem "mongo"
```

## Usage

### Default connection (localhost:27017/hecks)

```ruby
app = Hecks.boot(__dir__, adapter: :mongodb)
```

### Custom connection

```ruby
app = Hecks.boot(__dir__, adapter: {
  type: :mongodb,
  uri: "mongodb://user:pass@host:27017",
  database: "my_app"
})
```

## How it works

Each aggregate maps to a MongoDB collection (pluralized snake_case):
- `Pizza` → `pizzas` collection
- `GovernancePolicy` → `governance_policies` collection

Documents use `_id` as the aggregate UUID. All scalar attributes are stored as top-level fields.

## Repository interface

The generated `MongoRepository` implements the same interface as the memory adapter:

```ruby
app["Pizza"].find(id)           # find by UUID
app["Pizza"].save(pizza)        # upsert (insert or replace)
app["Pizza"].delete(id)         # delete by UUID
app["Pizza"].all                # all documents
app["Pizza"].count              # document count
app["Pizza"].clear              # delete all
app["Pizza"].query(             # filtered query
  conditions: { style: "Classic" },
  order_key: :name,
  order_direction: :asc,
  limit: 10,
  offset: 0
)
```

## Switching adapters

You can swap between memory, SQL, and MongoDB at any time:

```ruby
# Memory (default)
app = Hecks.boot(__dir__)

# SQLite
app = Hecks.boot(__dir__, adapter: :sqlite)

# MongoDB
app = Hecks.boot(__dir__, adapter: :mongodb)
```

The domain code is identical — only the adapter wiring changes.
