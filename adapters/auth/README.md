# auth/

Actor / role / session / authorization decision middleware.

| File | What |
|---|---|
| `auth.bluebook` | Bluebook for the auth adapter. |
| `auth.hecksagon` | Wiring : adapter_type, wires_to, named bindings. |
| `auth.rb` | Ruby extension — session middleware + actor lookup. Pre-bluebook lift surface ; `screen_routes.rb` + `session_store.rb` + `views/` remain at `../../ruby/hecks/extensions/auth/`. |
