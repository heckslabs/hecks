# frozen_string_literal: true

require "sqlite3"
require_relative "../../../../../adapters/driven/sqlite"
require_relative "read_only"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module SqliteStatus
          # One SQLite file read against the aggregates bound to it. The file is opened with
          # read-only (see {ReadOnly}) and only `PRAGMA table_info` and `sqlite_master` are read.
          class DatabaseReading
            ADAPTERS = %w[Sqlite SqlitePersistence].freeze
            # Tables the adapter keeps beside every aggregate's own.
            ABSENT = "absent: created on first open"
            SHARED_TABLE = /\A(events|hecks_\w+|sqlite_\w+)\z/

            # The files the registry's aggregates are persisted in, each with its aggregates.
            #
            # @param registry [Runtime::Registry] a described registry
            # @return [Hash{String => Array<Bluebook::Aggregate>}] absolute path to aggregates
            def self.targets(registry)
              registry.bluebooks.values.each_with_object({}) do |bluebook, found|
                bluebook.aggregates.each do |aggregate|
                  path = path_for(registry, bluebook, aggregate)
                  (found[path] ||= []) << aggregate if path
                end
              end
            end

            # @return [String, nil] the file the aggregate is bound to, nil unless SQLite
            def self.path_for(registry, bluebook, aggregate)
              bind = Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, aggregate)
              return unless ADAPTERS.include?(bind.adapter.to_s)

              settings = registry.binding_settings(bluebook.name, Ports::Persistence::VERB, bind.adapter)
              absolute(registry, registry.with_adapter_defaults(bind.adapter, aggregate, settings))
            rescue Runtime::WiringError
              nil
            end

            # @return [String] the settings' database, resolved against the registry's root
            def self.absolute(registry, settings)
              declared = settings.transform_keys(&:to_sym)[:database].to_s
              declared.start_with?("/") ? declared : File.join(registry.root || Dir.pwd, declared)
            end

            # @param path [String] the database file
            # @param aggregates [Array<Bluebook::Aggregate>] the aggregates bound to it
            def initialize(path, aggregates)
              @path = path
              @aggregates = aggregates
            end

            # @return [Hash] `database`, `tables` (one per aggregate) and `orphans`
            def row
              return { database: @path, state: ABSENT, tables: [], orphans: [] } unless File.file?(@path)

              db = ReadOnly.open(@path)
              present = db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
              { database: @path, state: "read", tables: @aggregates.map { |a| table_row(db, present, a) },
                orphans: orphans(present) }
            ensure
              db&.close
            end

            private

            def table_row(db, present, aggregate)
              base = { aggregate: aggregate.name, table: aggregate.storage_name }
              return base.merge(state: ABSENT) unless present.include?(base[:table])

              drift = drift_of(columns(db, base[:table]), expected(aggregate))
              base.merge(state: drift.key?(:missing) ? "drift" : "ok", **drift)
            end

            # Column names compare without regard to capitals, as the adapter's open does.
            def drift_of(held, wanted)
              held_names = held.map(&:downcase)
              wanted_names = wanted.map(&:downcase)
              missing = wanted.reject { |name| held_names.include?(name.downcase) }
              extra = held.reject { |name| wanted_names.include?(name.downcase) || name.casecmp?("id") }
              { missing: missing, extra: extra }.reject { |_, names| names.empty? }
            end

            def columns(db, table)
              db.execute(%(PRAGMA table_info("#{table.gsub('"', '""')}"))).map { |column| column[1] }
            end

            # The column names the adapter's codec persists, read without opening the adapter.
            def expected(aggregate)
              adapter = Hecks::Adapters::Sqlite.allocate
              adapter.instance_variable_set(:@aggregate, aggregate)
              adapter.send(:persisted_fields).map { |field| field[:name].to_s }
            end

            def orphans(present)
              known = @aggregates.flat_map { |a| [a.storage_name, "#{a.storage_name}_entries"] }
              (present - known).grep_v(SHARED_TABLE).map { |name| orphan(name) }
            end

            def orphan(name)
              stem = name.delete_suffix("_entries")
              owner = @aggregates.find { |a| [a.name, a.former_name].compact.map { |n| Naming.snake(n) }.include?(stem) }
              owner ? { table: name, belongs_to: owner.name, stored_as: owner.storage_name } : { table: name }
            end
          end
        end
      end
    end
  end
end
