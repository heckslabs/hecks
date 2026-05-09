# spec_helper.rb — in_memory_full_night
#
# Wires Hecks's gem environment + load path so the full-night spec can
# require BehaviorRuntime, FixtureLlmAdapter, and the local helpers
# without any tmpdir / heki / subprocess plumbing. The whole point of
# this slice is determinism + millisecond runtime.

HECKS_ROOT = File.expand_path("../../../../hecks", __dir__)
ENV["BUNDLE_GEMFILE"] = File.join(HECKS_ROOT, "Gemfile") \
  unless ENV["BUNDLE_GEMFILE"] && File.file?(ENV["BUNDLE_GEMFILE"])
require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

$LOAD_PATH.unshift File.join(HECKS_ROOT, "ruby")
$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "rspec"
require "hecks"
require "hecks/behaviors/behavior_runtime"
require "hecks/behaviors/aggregate_state"
require "hecks/behaviors/value"
require "hecks/adapters/fixture_llm_adapter"

FIXTURE_PATH = File.expand_path(
  "../../../../hecks/spec/fixtures/dream_responses.yaml", __dir__
)

RSpec.configure do |c|
  c.formatter = :progress
end
