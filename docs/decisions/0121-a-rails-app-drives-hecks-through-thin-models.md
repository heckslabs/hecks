# A Rails app drives Hecks through thin models

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24.

## Context

`docs/rails-integration.md` set out how a Rails app should sit on Hecks as a driving adapter,
without building any of it. A Rails developer reaching for Hecks instead of ActiveRecord needs
the pieces ActiveRecord gives them for free: a model class per table, routes, controllers,
form helpers, a way to show a refusal next to a field, and a test matcher. None of them may
author a rule a second time, and core Hecks must not gain a Rails or ActiveModel dependency.

## Decision

1. **The integration is its own gem, `packages/hecks-rails`.** It depends on `hecks`,
   `railties` and `activemodel`; nothing under `lib/hecks` requires Rails. A Rails app and
   the package name no `Hecks::Runtime` constant: they boot with `Hecks.boot(...,
   install_driving: false)` and hold the dispatcher it answers, so no top-level `Account`
   module is installed beside the app's own `Account` class.
2. **A model is a thin class over a handle.** `class Account < Hecks::Rails::Model;
   aggregate "Banking.Account"; end`. The class answers `find`, `all`, `count`, and every
   creating verb in both forms (`Account.open` the IR command, `Account.open!(...)` the
   dispatch). An instance wraps a core `Handle`: `record.freeze_account` answers the IR
   command and `record.freeze_account!` dispatches and raises `Hecks::Refused`. A reference
   is read explicitly, `transfer.source` the raw identity and `transfer.source_account`
   the record, looked up only when called. ActiveModel's `Naming`, `Conversion` and an
   empty `Errors` are the integration surface; presentation methods are allowed.
3. **A cop keeps models thin.** `HecksRails/ThinModel` refuses `validates`/`validate`, every
   `before_*`/`after_*`/`around_*` callback and every association macro inside a
   `Hecks::Rails::Model` subclass, because each would be a second author for a rule the
   bluebook already holds.
4. **Routes are derived, and Site Route rows win.** `hecks_routes "banking"` draws
   `resources <plural>, only: [:show]` per aggregate, a POST per command (a creating command
   on the collection, the rest on the member) and a GET per query on the collection. A
   `Route` row of the Site chapter whose `source` names a command or query gives that
   verb's path and method instead. No PUT, PATCH or DELETE is drawn.
5. **A controller has one named action per verb.** `include Hecks::Rails::Controller`
   defines the actions in a module of their own, so an app overrides one by name and calls
   `super`. A refusal is rescued once, added to the record's errors under
   `refusal.attribute` or `:base`, and answered with a 422. Who is acting comes from
   `hecks_actor_id`; the role check is the domain's own Governance grant, run by the
   dispatch, never a list in the controller. An action with no actor runs as an anonymous
   caller, which a command that declares a role refuses.
6. **Forms and availability reuse what exists.** `bluebook_form_for(record.command)` renders
   through `Hecks::Forms` (the field tree, the renderer and `Params.extract` for the post).
   `record.available_commands(as: user)` dry-runs each verb as that actor through the
   dispatcher's existing `dry_run?`; a refusal about one of the verb's own inputs means
   "needs input", not "unavailable".
7. **The app's files are projected.** The `:rails_app` projection writes one model per
   aggregate, one controller per aggregate and the routes file from a domain's IR, and
   `hecks launch.project_rails!` runs it into a Rails app. A Rails app keeps its domain in a
   top-level `bluebook/` (chapters, `.hecksagon`, `.world`, `environments/`, `.behaviors`,
   `translations/`), beside `bluebook.yml` and `vendor/`.

## Alternatives considered

- **Decorate every `Handle` at boot (`WebHandle`), as the design note proposed.** A Rails
  app wants a named class to put presentation methods on and for Zeitwerk to load; a
  decorator gives neither. Rejected for a thin subclass over the same handle.
- **A single generic `dispatch` action.** Rejected, as the design note already argued: no
  per-verb view, callback filter or override point.
- **Map `Unauthorized` to a 403.** It would make the package name a `Hecks::Runtime`
  class. Every refusal is a 422 with the refusal's own words; an app that wants a 403
  overrides the action.

## Consequences

- The fixture app under `packages/hecks-rails/spec/fixture_app` boots `examples/banking`
  (its chapters are linked, its wiring is the app's own) and its request spec runs with the
  package's own Gemfile, since the repository's bundle does not carry Rails.
- Entity commands (nested routes), index and query views, uploads and real-time updates
  stay open, as `docs/rails-integration.md` lists them.
