# examples/

*Examples* — here live the **reference uses** : domains and applications that show what Hecks looks like when someone actually picks it up and writes with it. *Pizzas* is the shape one reaches for first, the small-and-complete demonstration ; *banking*, *governance*, *bookshelf* turn the same grammar to other voices. They are **like a phrasebook** — not the language itself (that lives in *`bluebook/`*), but the language *spoken*, in real sentences, for someone who needs to hear it before they trust it. The deeper triage of what stays at this level arrives in Round 3 (inbox i128).

---

## pizzas/

A standalone Hecks domain with three runnable scripts demonstrating different framework features:

- **`app.rb`** — Full workflow: build gem, wire Application, use commands, collection proxies, DSL query objects (`Pizza.by_description`), subscribe to events
- **`repl_session.rb`** — Interactive domain building with the Session API, CalVer versioning, then play mode for command execution
- **`sql_app.rb`** — SQL schema and adapter generation with a live SQLite demo

```bash
ruby -Ilib examples/pizzas/pizzas.rb
ruby -Ilib examples/pizzas/repl_session.rb
ruby -Ilib examples/pizzas/sql_app.rb
```

## pizzas_rails/

Shows how to use a Hecks domain gem inside Rails. Uses `Hecks.configure` with database config and `include_ad_hoc_queries` for the full ActiveRecord-style API. Controllers use DSL query objects (`Pizza.by_description`, `Order.pending`). Domain objects come from the gem — no model files in the Rails app.

See `pizzas_rails/README.md` for setup instructions.

## multi_domain/

Three separate domains (pizzas, billing, shipping) sharing one event bus. When an order is placed, billing and shipping react automatically through events. No domain knows about the others.

```bash
ruby -Ilib examples/multi_domain/app.rb
```

## sinatra_app/

Generated from the pizzas domain with `hecks generate:sinatra`. An editable Sinatra app with routes wired to the domain — add auth, middleware, custom endpoints on top.

```bash
cd examples/sinatra_app && bundle install && ruby app.rb
```

## Serving any domain

From any directory with a `domain.rb`:

```bash
hecks serve                    # REST API + SSE on port 9292
hecks serve --rpc              # JSON-RPC
hecks serve --mcp              # MCP for AI agents
hecks serve examples/pizzas    # serve from a path
```
