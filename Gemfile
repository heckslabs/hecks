# frozen_string_literal: true

source "https://rubygems.org"

gem "pg", "~> 1.5"
gem "sqlite3", "~> 2.0"

# For testing GoogleAuthentication, lib/hecksagain/adapters/driven/
# google_authentication.rb — lazily required there, same reasoning
# `pg` above already holds itself to: a domain that never binds
# `authentication` to this adapter should never need these installed.
gem "oauth2", "~> 2.0"
gem "google-id-token", "~> 1.4"

# For testing Adapters::Lambda / Runtime::RemoteDispatcher,
# lib/hecksagain/adapters/driven/lambda/client.rb — lazily required
# there, same reasoning as oauth2/google-id-token above: a domain
# that never binds `dispatched_by("Lambda")`/`persisted_by("Lambda")`
# should never need this installed.
gem "aws-sdk-lambda", "~> 1.0"

# For lib/hecksagain/forms/app.rb — lazily required there, same
# reasoning as the adapters above: a domain that never boots the
# forms surface should never need a Rack implementation
# installed. rackup/webrick supply `bin/present`'s own dev server;
# neither is a runtime dependency of the forms app itself,
# which only needs `Rack::Request`/`Rack::Response` and is handed to
# whatever server the embedding project already runs.
gem "rack", "~> 3.0"
gem "rackup", "~> 2.0"
gem "webrick", "~> 1.9"
gem "rack-test", "~> 2.0"

# PINNED, NOT LEFT TO THE RESOLVER — oauth2's own dependency chain
# pulls in a real `json` gem where none was in this bundle before
# (Ruby's own bundled default, 2.7.2, answered every require here
# until now). A newer json gem changes JSON.pretty_generate's own
# formatting for an empty array/hash — spec/ir_golden_spec.rb and
# spec/reference_golden_spec.rb pin exact bytes against the default
# Ruby ships with, so an unpinned resolver silently upgrading json
# breaks fixtures that have nothing to do with oauth2 at all.
gem "json", "2.7.2"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "simplecov", "~> 0.22"

  # Local-only: splits the suite across processes (one per core, by
  # default) so `bundle exec parallel_rspec spec` uses the machine's own
  # idle cores instead of running everything on one. NOT wired into CI
  # or the pre-push hook's `io: true` run — those specs share one real
  # Postgres service container, and parallelizing against it needs
  # per-worker database naming this project doesn't have yet (no
  # ActiveRecord to lean on for that, unlike parallel_tests' own
  # built-in Rails support).
  gem "parallel_tests", "~> 4.7"

  # A REAL, LEAN GATE — .rubocop.yml is tuned to this codebase's own
  # already-established style (long deliberate prose comments,
  # module_function-heavy modules, Struct-based value types) rather than
  # a generic default fought line by line. rubocop-rspec covers the 174
  # files under spec/ with RSpec-aware cops a plain rubocop run has no
  # opinion on at all.
  gem "rubocop", "~> 1.69", require: false
  gem "rubocop-rspec", "~> 3.3", require: false
end
