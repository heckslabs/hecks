# spec_helper.rb — Phase 0h in_memory_adapter
#
# Wires the bundle env (Hecks's Gemfile) and load path so the proving
# spec can require the FixtureLlmAdapter + TestAdapters directly. No
# tmpdir is needed — these specs are pure unit tests against the
# adapter classes, no hecks-life subprocess.

HECKS_ROOT = File.expand_path("../../../../hecks", __dir__)
ENV["BUNDLE_GEMFILE"] ||= File.join(HECKS_ROOT, "Gemfile")
require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

$LOAD_PATH.unshift File.join(HECKS_ROOT, "ruby")
$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "rspec"
require "hecks/adapters/fixture_llm_adapter"
require "hecks/adapters/test_adapters"

FIXTURE_PATH = File.expand_path(
  "../../../../hecks/spec/fixtures/dream_responses.yaml", __dir__
)

RSpec.configure do |c|
  c.formatter = :documentation
end
