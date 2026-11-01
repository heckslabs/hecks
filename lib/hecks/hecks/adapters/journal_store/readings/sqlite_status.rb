# frozen_string_literal: true

require "json"
require_relative "sqlite_status/database_reading"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # How the SQLite databases a domain's worlds name stand against its aggregates. Each file
        # is opened read-only, never through the adapter (whose open adds missing columns), so the
        # reading writes nothing and shows the drift before an open heals it or a write meets it.
        module SqliteStatus
          # @param domain [Hash, String] the domain directory
          # @return [Hash] `text:` the status as JSON, one row per database file
          # @raise [Runtime::NotFound] if the directory cannot be loaded
          def sqlite_status(domain:)
            answering { JSON.pretty_generate(SqliteStatus.of(Hecks.describe(plain(domain)).registry)) }
          end

          # @param registry [Runtime::Registry] a described registry
          # @return [Array<Hash>] one row per SQLite file, in the order the aggregates name them
          def self.of(registry)
            DatabaseReading.targets(registry).map do |path, aggregates|
              DatabaseReading.new(path, aggregates).row
            end
          end
        end
      end
    end
  end
end
