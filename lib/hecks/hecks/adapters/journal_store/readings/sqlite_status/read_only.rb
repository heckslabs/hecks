# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module SqliteStatus
          # Opens an existing SQLite file so that reading it creates nothing beside it. A plain
          # read-only open of a database in write-ahead-log mode makes its `-wal` and `-shm`
          # files, so a database with no `-wal` file is opened `immutable`, which skips them
          # altogether. One that has a `-wal` file holds changes the reading must see, and
          # already has the files a read-only open needs.
          module ReadOnly
            UNRESERVED = %r{[^A-Za-z0-9\-._~/]}

            # @param path [String] a database file that exists
            # @return [SQLite3::Database] the open, read-only database; the caller closes it
            def self.open(path)
              require "sqlite3"
              return SQLite3::Database.new(path, readonly: true) if File.exist?("#{path}-wal")

              SQLite3::Database.new("file:#{escape(path)}?immutable=1",
                                    flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
            end

            # @return [String] the path with every byte a URI reserves written as a percent escape
            def self.escape(path) = path.gsub(UNRESERVED) { |char| char.bytes.map { |byte| format("%%%02X", byte) }.join }
          end
        end
      end
    end
  end
end
