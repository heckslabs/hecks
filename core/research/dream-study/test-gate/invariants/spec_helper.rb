# spec_helper.rb — Phase 0g invariants
#
# Wires the bundle env (Hecks's Gemfile) and load path so the math
# specs can require the dispatch helper. Each spec uses a tmpdir as
# HECKS_INFO so test runs are isolated from Miette's live state.

HECKS_ROOT = File.expand_path("../../../../hecks", __dir__)
ENV["BUNDLE_GEMFILE"] ||= File.join(HECKS_ROOT, "Gemfile")
require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

$LOAD_PATH.unshift File.join(HECKS_ROOT, "ruby")
$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "rspec"
require "dispatch_helper"

RSpec.configure do |c|
  c.formatter = :documentation
end
