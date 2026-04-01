# Rails Generators

Three Rails generators, registered automatically via the Railtie.

## `active_hecks:init`

Full setup — run once when adding Hecks to a Rails app.

```bash
rails generate active_hecks:init
```

What it does:
- Adds `gem "hecks_on_rails"` to Gemfile (if not present)
- Detects `*_domain` gems (local directory or installed gem)
- Creates `config/initializers/hecks.rb`
- Creates `app/models/HECKS_README.md`
- Adds `hecks/test_helper` to spec/test helpers
- Runs `active_hecks:live` automatically

## `active_hecks:live`

Sets up real-time event streaming. Run automatically by `init`, or standalone.

```bash
rails generate active_hecks:live
```

What it does:
- Enables `action_cable/engine` in `config/application.rb`
- Creates `config/cable.yml` (async adapter for development)
- Creates `app/channels/application_cable/` files
- Mounts ActionCable at `/cable` in routes
- Pins `@hotwired/turbo-rails` via importmap
- Adds `import "@hotwired/turbo-rails"` to `application.js`
- Adds `action_cable_meta_tag` to layout
- Adds `turbo_stream_from "hecks_live_events"` to layout

## `active_hecks:migration`

Generates SQL migrations from domain changes.

```bash
rails generate active_hecks:migration
```

Compares the current domain against the saved snapshot, generates incremental SQL
to `db/hecks_migrate/`. Apply with `rake hecks:db:migrate`.
