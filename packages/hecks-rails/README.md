# hecks-rails

Rails as a driving adapter over a Hecks domain: models, routes, controllers and forms without
ActiveRecord. A Rails app keeps its models, routes, controllers, form helpers and `errors`, and
every rule lives in the bluebook. Rails authenticates and renders; the domain decides.

An app's own code never names Hecks: it has a `bluebook/` directory, `gem "hecks-rails"`, and
ordinary Rails files.

## What it provides

- **Models**: one generated per aggregate, inheriting a generated `ApplicationRecord`.
- **Routes**: `resources :accounts` draws a `show` and a POST per command.
- **Controllers**: a named action per command; refusals land in `errors` and answer 422, 403 or
  404 by kind.
- **Actor**: each request runs as `current_user`, so role-gated commands refuse when nobody is
  signed in.
- **Validations**: `record.valid_for?(:verb, params)` asks the domain whether a command would be
  accepted and fills `errors` with every reason.
- **Forms and pages**: `command_form_for`, plus a working UI per aggregate with no view file.
- **Testing**: the `be_refused_with` RSpec matcher (`hecks/rails/rspec`).

The gem version equals the `hecks` gem version it depends on. See `docs/rails-integration.md`
for the design, what is generated, and the ideas that were rejected.
