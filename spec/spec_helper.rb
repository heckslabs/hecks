# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Families and adapters are declared ONCE and shared across every domain — that
# is the whole point of the inverted arrow. The specs build temp domains in
# /tmp, where walking up finds no boundary, so they name the repo's explicitly
# rather than each carrying a private copy to drift from.
SHARED = File.expand_path("..", __dir__)

RSpec.configure do |config|
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end
