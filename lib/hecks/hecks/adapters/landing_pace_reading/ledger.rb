# frozen_string_literal: true

require_relative "../journal_store/readings/sqlite_status/database_reading"

module Hecks
  module Adapters
    class LandingPaceReading
      # Finds the file the delivery package's `Landing` is kept in, from a booted registry.
      module Ledger
        # The bluebook and the aggregate whose events are measured.
        DOMAIN = "Delivery"
        AGGREGATE = "Landing"

        module_function

        # @param registry [Runtime::Registry, nil] the booted registry
        # @return [String, nil] the SQLite file `Landing` is bound to; nil when it is kept
        #   elsewhere or the file does not exist
        def path(registry)
          return unless registry

          bluebook = registry.bluebooks.values.find { |candidate| candidate.name.to_s == DOMAIN }
          landing = bluebook&.aggregates&.find { |candidate| candidate.hecks_name == AGGREGATE }
          bound(registry, bluebook, landing) if landing
        end

        def bound(registry, bluebook, landing)
          path = JournalStore::Readings::SqliteStatus::DatabaseReading.path_for(registry, bluebook, landing)
          path if path && File.file?(path)
        end
      end
    end
  end
end
