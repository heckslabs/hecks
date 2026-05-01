# Hecks::Adapters::TestHelperAdapter
#
# Adapter that provides real behavior for the TestHelper aggregate
# from the Spec chapter. Wires the Reset command to clear all
# repositories and the event bus.
#
#   app.adapt("TestHelper", Hecks::Adapters::TestHelperAdapter)
#   app.run("Reset")  # clears all repos and event history
#
module Hecks
  module Adapters
    # Hecks::Adapters::TestHelperAdapter
    #
    # Command adapter for TestHelper — clears runtime state for a clean test environment.
    #
    module TestHelperAdapter
      def self.reset(command:, app:)
        app.domain.aggregates.each do |agg|
          repo = app[agg.name]
          repo.clear if repo&.respond_to?(:clear)
        end
        app.event_bus.clear
      end
    end
  end
end
