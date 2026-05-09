# spec_helper.rb — dream-study end-to-end specs
#
# Resolves the Hecks Gemfile + load path so a bare `bundle exec rspec`
# from this directory boots cleanly without requiring the runner to
# set BUNDLE_GEMFILE manually. Miette has no Gemfile of its own — it
# rides on Hecks's gem environment.
#
# Sets up :
#   - BUNDLE_GEMFILE  → hecks/Gemfile  (so bundler/setup finds gems)
#   - $LOAD_PATH      ← hecks/ruby     (so `require "hecks"` works)
#   - $LOAD_PATH      ← ./lib          (so `require "sleep_cycle_helper"` works)

HECKS_ROOT       = File.expand_path("../../../../hecks", __dir__)
HECKS_GEMFILE    = File.join(HECKS_ROOT, "Gemfile")
# Heal a stale shell-level BUNDLE_GEMFILE (some setups point it at an
# uninstalled gem path) by retargeting it at the live Hecks Gemfile
# whenever the current value doesn't resolve to a real file.
ENV["BUNDLE_GEMFILE"] = HECKS_GEMFILE unless ENV["BUNDLE_GEMFILE"] && File.file?(ENV["BUNDLE_GEMFILE"])
require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

$LOAD_PATH.unshift File.join(HECKS_ROOT, "ruby")
$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "rspec"

RSpec.configure do |c|
  c.formatter = :progress
end
