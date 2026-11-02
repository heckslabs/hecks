# frozen_string_literal: true

require_relative "reader"
require_relative "../sqlite_status/read_only"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # A SQLite file opened read-only, so reading it makes no file beside it (see
          # {SqliteStatus::ReadOnly}).
          class SqliteReader < Reader
            # @param path [String] the database file
            # @return [SqliteReader, nil] nil when the file does not exist
            def self.open(path)
              new(SqliteStatus::ReadOnly.open(path)) if File.file?(path)
            end

            def initialize(db)
              super()
              @db = db
              @db.results_as_hash = true
            end

            # Closes the database.
            def close = @db.close

            private

            def run(sql, binds) = @db.execute(sql, binds)

            def json(column, field) = "json_extract(#{column}, '$.#{field}')"

            def table?(name)
              @db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).any?
            end
          end
        end
      end
    end
  end
end
