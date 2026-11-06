# frozen_string_literal: true

require_relative "reader"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module EventTrace
          # A PostgresRevision database over a session that refuses every write.
          class PostgresReader < Reader
            # @param name [String] the bluebook the settings belong to, for refusals
            # @param settings [Hash] the world's persistence settings
            # @return [PostgresReader]
            def self.open(name, settings)
              db = Hecks::Adapters::PostgresRevision.connect_for(name, settings, provision: false)
              db.exec("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
              new(db)
            end

            def initialize(db)
              super()
              @db = db
            end

            # Closes the connection.
            def close = @db.close

            private

            def run(sql, binds)
              numbered = sql.gsub("?").with_index(1) { |_, index| "$#{index}" }
              @db.exec_params(numbered, binds).to_a
            end

            def json(column, field) = "#{column}->>'#{field}'"

            def table?(name) = !@db.exec_params("SELECT to_regclass($1::text)", [name]).getvalue(0, 0).nil?
          end
        end
      end
    end
  end
end
