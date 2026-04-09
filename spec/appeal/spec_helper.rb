# spec/appeal/spec_helper.rb
#
# Minimal RSpec configuration for Appeal IDE domain tests.
# Loads Hecks and configures RSpec for fast, isolated specs.
#
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "hecks"

RSpec.configure do |config|
  config.formatter = :progress
end
