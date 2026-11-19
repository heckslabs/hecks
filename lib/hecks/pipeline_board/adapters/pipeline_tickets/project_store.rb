# frozen_string_literal: true

require_relative "../probe"
require_relative "../../../hecks/adapters/journal_store/readings/sqlite_status/read_only"
require_relative "project_store/world_path"
require_relative "project_store/table"

module Hecks
  module Adapters
    module PipelineBoard
      # Another project's Tickets store, read in place and only read. The project is never booted,
      # so no watcher or policy of it runs and none of its pending work is settled: its checkout's
      # local world is read as text for the database it names, and the database is opened
      # read-only (`immutable` when it has no `-wal` file, so the read creates nothing beside it).
      # A helper of {PipelineTickets}, which answers the `Tickets` port's `ProjectWork`.
      class ProjectStore
        # The columns a Work item is read with: the first are needed, the rest read when present.
        WORK_NEEDED = %w[work title status step epic].freeze
        WORK_WANTED = %w[area priority category claimed_by claimed_at budget_minutes yield_count reason
                         decision].freeze
        # The columns an Epic is read with, likewise.
        EPIC_NEEDED = %w[epic title].freeze
        EPIC_WANTED = %w[outcome tier decision].freeze

        # @param checkout [String] the project's checkout
        def initialize(checkout:)
          @checkout = checkout
        end

        # @return [Hash{Symbol => Array<Hash>}] `works` and `epics`, every record of each, plain
        # @raise [Unavailable] when no local world names the store, the store is missing, or it
        #   holds no Work table or lacks a needed column
        def read
          db = open_store
          { works: works(db), epics: epics(db) }
        ensure
          db&.close
        end

        # @return [String] the database the checkout's `Tickets` world names, kept once found
        # @raise [Unavailable] when none is named
        def database
          @database ||= WorldPath.database(@checkout) or
            raise Unavailable, "no local world in #{@checkout} names a Tickets store"
        end

        private

        def open_store
          raise Unavailable, "the Tickets store #{database} does not exist" unless File.exist?(database)

          JournalStore::Readings::SqliteStatus::ReadOnly.open(database)
        end

        def works(db)
          Table.rows(db, "work", needed: WORK_NEEDED, wanted: WORK_WANTED) or
            raise Unavailable, "the Tickets store #{database} holds no Work table"
        end

        # A store that has never held an epic has no epic table, and answers none.
        def epics(db) = Table.rows(db, "epic", needed: EPIC_NEEDED, wanted: EPIC_WANTED) || []
      end
    end
  end
end
