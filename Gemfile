# frozen_string_literal: true

source "https://rubygems.org"

gem "pg", "~> 1.5"
gem "sqlite3", "~> 2.0"

# Test-only: the Google authentication adapter, required lazily.
gem "oauth2", "~> 2.0"
gem "google-id-token", "~> 1.4"

# Test-only: the Lambda adapter and remote dispatcher, required lazily.
gem "aws-sdk-lambda", "~> 1.0"

# Used by qa/lambda_handler.rb to fetch secrets at Lambda cold start.
gem "aws-sdk-secretsmanager", "~> 1.0"

# The forms app needs only Rack::Request/Response; rackup and webrick serve bin/present.
gem "rack", "~> 3.0"
gem "rackup", "~> 2.0"
gem "webrick", "~> 1.9"
gem "rack-test", "~> 2.0"

# Pinned: newer json gems change JSON.pretty_generate output for empty arrays/hashes,
# which the golden specs (ir_golden_spec, reference_golden_spec) pin byte for byte.
gem "json", "2.7.2"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "simplecov", "~> 0.22"

  # Local-only: not used in CI, whose io specs share one Postgres and need per-worker databases.
  gem "parallel_tests", "~> 4.7"

  gem "rubocop", "~> 1.69", require: false
  gem "rubocop-rspec", "~> 3.3", require: false

  # Local-only: `bundle exec guard` watches lib/spec and reruns the
  # matching specs on save. Not wired into CI or the pre-push hook.
  gem "guard", "~> 2.19", require: false
  gem "guard-rspec", "~> 4.7", require: false

  # Local-only: lets Guard raise a system notification (Terminal
  # Notifier on macOS, libnotify on Linux) when a run finishes.
  # Notiffany already tries several backends in turn and skips
  # whichever one isn't installed, so both gems are safe to list
  # together on a machine that only has one available.
  install_if -> { RUBY_PLATFORM.include?("darwin") } do
    gem "terminal-notifier", "~> 2.0", require: false
    gem "terminal-notifier-guard", "~> 1.7", require: false
  end

  install_if -> { RUBY_PLATFORM.include?("linux") } do
    gem "libnotify", "~> 0.9", require: false
  end
end
