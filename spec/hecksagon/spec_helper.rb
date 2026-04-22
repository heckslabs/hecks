# spec/hecksagon/spec_helper.rb
#
# Minimal RSpec configuration for Hecksagon DSL and Structure specs.
# Loads Hecks so autoloads resolve; specs run in isolation with no IO.
#
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "hecks"

RSpec.configure do |config|
  config.formatter = :progress
end
