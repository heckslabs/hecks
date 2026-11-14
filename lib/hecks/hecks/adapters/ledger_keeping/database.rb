# frozen_string_literal: true

require "sqlite3"

module Hecks
  module Adapters
    module LedgerKeeping
      # Raised when the file's lock could not be taken within the wait.
      class Held < StandardError; end

      # The SQLite file the AgentRun records live in, as the pipeline's upkeep sees it: how many
      # journal entries a compaction would delete, and a vacuum. Every lock is taken on a short
      # bound, so a file another process holds is reported (`Held`), never waited for.
      class Database
        # @param path [String] the database file
        # @param table [String] the aggregate's storage name; its journal is `<table>_entries`
        # @param wait [Numeric] seconds a lock may be waited for
        def initialize(path, table:, wait:)
          @path = path
          @table = table
          @wait = wait
        end

        # @return [String] the file
        attr_reader :path

        # @return [Integer] the file's size in bytes
        def bytes = File.size(@path)

        # The journal entries between the compaction floor and the projection checkpoint: the rows
        # `SchemaRevision.Compact` would delete. Counted under the write lock, so a held file is
        # known before a compaction is started.
        #
        # @return [Integer] how many entries are compactable
        # @raise [Held] when the write lock is not taken within the wait
        def compactable
          locked("IMMEDIATE") do |db|
            floor, through = db.get_first_row(
              "SELECT compacted_through, last_sequence FROM hecks_checkpoints WHERE aggregate_table = ?", [@table]
            ).to_a.map(&:to_i)
            db.get_first_value("SELECT COUNT(*) FROM \"#{@table}_entries\" WHERE sequence > ? AND sequence <= ?",
                               [floor, through]).to_i
          end
        end

        # Gives the pages deleted rows freed back to the file. The exclusive lock is taken first on
        # the short bound, so a file that is not quiet is refused before the copy starts.
        #
        # @return [Hash{Symbol => Integer}] `before` and `after`, the file's bytes
        # @raise [Held] when the exclusive lock is not taken within the wait
        def vacuum!
          before = bytes
          locked("EXCLUSIVE") { nil }
          open_database { |db| db.execute("VACUUM") }
          { before: before, after: bytes }
        rescue SQLite3::BusyException => e
          raise Held, e.message
        end

        private

        # Runs the block holding the lock, then lets it go.
        def locked(mode)
          open_database do |db|
            db.execute("BEGIN #{mode} TRANSACTION")
            begin
              yield db
            ensure
              db.execute("ROLLBACK TRANSACTION") if db.transaction_active?
            end
          end
        rescue SQLite3::BusyException => e
          raise Held, e.message
        end

        def open_database
          db = SQLite3::Database.new(@path)
          db.busy_handler_timeout = (@wait * 1000).to_i
          yield db
        ensure
          db&.close
        end
      end
    end
  end
end
