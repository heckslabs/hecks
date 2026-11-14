# frozen_string_literal: true

require_relative "database"
require_relative "../journal_store/readings/sqlite_status/database_reading"

module Hecks
  module Adapters
    module LedgerKeeping
      # Finds the AgentRun records' file in a booted registry, and the world's `ledger_care` row:
      # the compactable entries that make a beat compact, and the seconds a lock is waited for.
      module Ledger
        # The aggregate whose journal is kept small.
        AGGREGATE = "AgentRun"

        # The Tickets world verb that carries the line and the wait.
        VERB = "ledger_care"

        # Entries compactable before a beat compacts, when the world names none.
        ENTRIES = 20_000

        # Seconds a lock is waited for, when the world names none.
        WAIT_SECONDS = 3

        module_function

        # @param registry [Runtime::Registry, nil] the booted registry
        # @return [Database, nil] the AgentRun file; nil when the records are not kept in SQLite
        def database(registry)
          return unless registry

          registry.bluebooks.each_value do |bluebook|
            aggregate = bluebook.aggregates.find { |candidate| candidate.hecks_name == AGGREGATE }
            path = aggregate && file_of(registry, bluebook, aggregate)
            return Database.new(path, table: aggregate.storage_name, wait: setting(registry, :wait_seconds)) if path
          end
          nil
        end

        # @param registry [Runtime::Registry, nil]
        # @param key [Symbol] `:entries` or `:wait_seconds`
        # @return [Numeric] the world's value, else its default
        def setting(registry, key)
          declared = registry&.world("Tickets")&.for_verb(VERB) || {}
          declared[key] || { entries: ENTRIES, wait_seconds: WAIT_SECONDS }.fetch(key)
        end

        # @return [String, nil] the SQLite file the aggregate is bound to, nil when it is not SQLite
        def file_of(registry, bluebook, aggregate)
          path = JournalStore::Readings::SqliteStatus::DatabaseReading.path_for(registry, bluebook, aggregate)
          path if path && File.file?(path)
        end
      end
    end
  end
end
