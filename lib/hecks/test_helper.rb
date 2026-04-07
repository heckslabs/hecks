  # = Hecks::TestHelper
  #
  # Test support module that automatically resets Hecks state between tests.
  # Clears all memory adapter stores and event bus history so each test starts
  # with a clean slate.
  #
  # Expects a global +APP+ constant holding a {Hecks::Runtime} instance,
  # which is the standard convention for Hecks test suites.
  #
  # == RSpec (auto-hooks)
  #
  # Just require this file and it hooks in automatically. It sets the load
  # strategy to +:memory+ before the suite and calls +reset!+ after each example.
  #
  #   # spec_helper.rb
  #   require "hecks/test_helper"
  #
  # == Minitest
  #
  # Include the module and call +reset!+ manually in setup/teardown:
  #
  #   class ActiveSupport::TestCase
  #     include Hecks::TestHelper
  #
  #     teardown do
  #       Hecks::TestHelper.reset!
  #     end
  #   end
  #
module Hecks
  # Hecks::TestHelper
  #
  # Test support module that resets Hecks runtime state between tests for a clean slate.
  #
  module TestHelper
    # Resets all runtime state for a clean test environment. Clears every
    # aggregate's repository (memory adapter store) and the event bus history.
    #
    # Does nothing if the +APP+ constant is not defined or is not a
    # {Hecks::Runtime} instance, making it safe to call unconditionally.
    #
    # @return [void]
    def self.reset!
      return unless defined?(APP) && APP.is_a?(Hecks::Runtime)

      # Clear all memory adapter stores
      APP.domain.aggregates.each do |agg|
        repo = APP[agg.name]
        repo.clear if repo&.respond_to?(:clear)
      end

      # Clear event history
      APP.event_bus.clear
    end
  end
end

# Auto-hook into RSpec if it's loaded
if defined?(RSpec)
  RSpec.configure do |config|
    config.before(:suite) do
      Hecks.load_strategy = :memory
    end

    config.after(:each) do
      Hecks::TestHelper.reset!
    end
  end
end
