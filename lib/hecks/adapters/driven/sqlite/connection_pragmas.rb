module Hecks
  module Adapters
    class Sqlite
      # The settings a Sqlite store applies to a file when it opens it: the journal mode that lets
      # readers run beside a writer, and the explicit fsync policy.
      class ConnectionPragmas
        # Journal modes a world may name, each safe to interpolate into a PRAGMA.
        MODES = %w[wal delete].freeze

        # @param journal_mode [String, Symbol] "wal" or "delete"
        # @return [String] the mode, lower case
        # @raise [ArgumentError] if the mode is not "wal" or "delete"
        def self.mode!(journal_mode)
          mode = journal_mode.to_s.downcase
          return mode if MODES.include?(mode)

          raise ArgumentError, "journal_mode must be one of #{MODES.join(", ")}, not #{journal_mode.inspect}"
        end

        # @param db [SQLite3::Database] the open connection, its busy handler already set
        # @param journal_mode [String, Symbol] "wal" or "delete"
        # @raise [ArgumentError] if the mode is not "wal" or "delete"
        def initialize(db, journal_mode: "wal")
          @db   = db
          @mode = self.class.mode!(journal_mode)
        end

        # Switches the file to the journal mode when it is not already there, then sets the fsync
        # policy. A switch that finds the file held leaves the mode as it is: the open goes on.
        #
        # @return [void]
        def apply!
          switch_journal_mode unless in_memory? || current_mode == @mode
          # The append is the recovery commit point, so the fsync policy is explicit.
          @db.execute("PRAGMA synchronous = FULL")
        end

        private

        def current_mode = @db.get_first_value("PRAGMA journal_mode").to_s.downcase

        def in_memory? = @db.filename.to_s.empty? || @db.filename == ":memory:"

        def switch_journal_mode
          @db.execute("PRAGMA journal_mode = #{@mode}")
        rescue SQLite3::BusyException, SQLite3::LockedException
          nil
        end
      end
    end
  end
end
