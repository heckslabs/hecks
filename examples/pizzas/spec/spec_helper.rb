# spec_helper.rb — Pizzas example domain test config
#
# Loads Hecks and configures RSpec for fast, isolated specs
# using in-memory adapters.

$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
require "hecks"

RSpec.configure do |config|
  config.formatter = :documentation
  config.order = :defined
end
