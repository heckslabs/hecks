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

        # Hours a delivered outbox row is kept, when the world names none.
        OUTBOX_HOURS = 1

        module_function

        # @param registry [Runtime::Registry, nil] the booted registry
        # @return [Database, nil] the AgentRun file; nil when the records are not kept in SQLite
        def database(registry)
          bluebook, aggregate, path = home(registry)
          return unless bluebook

          Database.new(path, table: aggregate.storage_name, wait: setting(registry, :wait_seconds))
        end

        # The directory a compaction boots: where the bluebook that declares the AgentRun records
        # keeps its files, which is not the registry's root when the registry booted a checkout.
        #
        # @param registry [Runtime::Registry, nil] the booted registry
        # @return [String, nil] the shallowest directory of that bluebook's sources; nil when the
        #   records are not kept in SQLite
        def directory(registry)
          bluebook, = home(registry)
          return unless bluebook

          Array(registry.bluebook_sources[bluebook.name]).map { |source| File.dirname(source) }
                                                         .min_by { |dir| dir.count("/") } || registry.root
        end

        # @return [Array(Object, Object, String), nil] the bluebook, the aggregate and the SQLite
        #   file of the first bluebook that declares AgentRun in a file
        def home(registry)
          return unless registry

          registry.bluebooks.each_value do |bluebook|
            aggregate = bluebook.aggregates.find { |candidate| candidate.hecks_name == AGGREGATE }
            path = aggregate && file_of(registry, bluebook, aggregate)
            return [bluebook, aggregate, path] if path
          end
          nil
        end

        # @param registry [Runtime::Registry, nil]
        # @param key [Symbol] `:entries`, `:wait_seconds` or `:outbox_hours`
        # @return [Numeric] the world's value, else its default
        def setting(registry, key)
          declared = registry&.world("Tickets")&.for_verb(VERB) || {}
          declared[key] || { entries: ENTRIES, wait_seconds: WAIT_SECONDS, outbox_hours: OUTBOX_HOURS }.fetch(key)
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
