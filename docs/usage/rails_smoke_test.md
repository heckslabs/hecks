# Rails Smoke Test

Boots the `examples/pizzas_rails` app as a real subprocess and runs HTTP
smoke tests against it. Verifies the Rails integration works end-to-end:
server boots, pages render, CRUD operations succeed, validation rejects
invalid input.

## Running

```bash
bundle exec rspec hecksties/spec/rails_smoke_spec.rb --tag slow
```

## What it covers

| Test | Method | Expected |
|------|--------|----------|
| Health check | `GET /up` | 200 |
| Root page | `GET /` | < 500 |
| Pizza index | `GET /pizzas` | 200 |
| New form | `GET /pizzas/new` | 200 |
| Create (valid) | `POST /pizzas` | 302 redirect |
| Create (invalid) | `POST /pizzas` with empty params | 422 |
| Show | `GET /pizzas/:id` | 200 |
| Edit form | `GET /pizzas/:id/edit` | 200 |
| Update | `PATCH /pizzas/:id` | 302 redirect |
| Delete | `DELETE /pizzas/:id` | 302 redirect |

## How it works

The spec spawns `bundle exec bin/rails server` on a random free port,
waits for the health check endpoint to respond, then sends HTTP requests
using `Net::HTTP`. Each test that needs a specific pizza creates one
first via POST, then extracts the ID from the `Location` header.

The test is tagged `:slow` so it is excluded from the default sub-second
RSpec run.

## Rails app structure

The `examples/pizzas_rails` app uses:

- `Hecks.configure` with the memory adapter (no database)
- `PizzasController` with standard scaffold actions
- ActiveModel validations wired by `ActiveHecks::ValidationWiring`
- Minimal ERB views (no asset pipeline complexity)
