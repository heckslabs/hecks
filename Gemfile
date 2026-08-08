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
end
