# spec/appeal/spec_helper.rb
#
# Minimal RSpec configuration for Appeal IDE domain tests.
# Loads Hecks and configures RSpec for fast, isolated specs.
#
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "hecks"
# Hecks::Appeal isn't autoloaded by `require "hecks"` — chapters are
# opt-in. Pull the Appeal chapter explicitly so the specs can refer
# to `Hecks::Appeal.definition` without `uninitialized constant`.
require "hecks/chapters/appeal"

RSpec.configure do |config|
  config.formatter = :progress
end
