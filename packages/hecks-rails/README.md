# hecks-rails

Drive a Hecks domain from a Rails app: thin models, routes drawn from the domain's verbs, and
controllers with one named action per verb. The rules stay in the bluebook; nothing here
authors one. [ADR 0121](../../docs/decisions/0121-a-rails-app-drives-hecks-through-thin-models.md)
records the decisions and [docs/rails-integration.md](../../docs/rails-integration.md) the
reasoning and the open items.

## Set up an app

Keep the domain in a top-level `bluebook/` beside `bluebook.yml` and `vendor/`:

```text
bluebook/
  banking.bluebook            chapters
  banking.hecksagon           wiring
  banking.world               values
  banking.behaviors           behavior tests
  environments/test.world     the overlay Rails.env picks
  translations/               era translation edges
bluebook.yml
vendor/
```

Add `gem "hecks-rails"` and write the models, controllers and routes from the chapters:

```sh
hecks launch.project_rails! dir.value=.
```

A file the app already has is left alone, so a model can grow presentation methods.

## Use it

```ruby
class Account < Hecks::Rails::Model
  aggregate "Banking.Account"
end

account = Account.open!(customer: "c1", number: { value: "a1" }, kind: { name: "current" })
account.freeze_account          # the verb's IR command
account.freeze_account!         # dispatches; raises Hecks::Refused, kept in account.errors
account.customer_record         # the referenced Customer, looked up now
account.available_commands(as: current_user)
```

```ruby
Rails.application.routes.draw do
  hecks_routes "banking"        # POST per command, GET per query, show per aggregate
end

class AccountsController < ApplicationController
  include Hecks::Rails::Controller

  drives Account
end
```

A refused verb answers 422 with the rule's words. The actor is `hecks_actor_id` (else
`current_user`), and the domain's Governance grants decide what they may do. In a view,
`bluebook_form_for(@account.freeze_account)` renders the verb's form. In a spec, `require
"hecks/rails/rspec"` and write `expect(response).to be_refused_with("…")`. In `.rubocop.yml`,
`require: hecks/rails/rubocop` turns on `HecksRails/ThinModel`, which refuses validations,
callbacks and associations in a model.

## Run the specs

The repository's bundle carries no Rails, so the package has its own:

```sh
cd packages/hecks-rails
bundle install
bundle exec rake
```

`spec/fixture_app` is a Rails app that links the `examples/banking` chapters into its
`bluebook/`; its request spec opens an account, freezes it, and is refused a second freeze.
