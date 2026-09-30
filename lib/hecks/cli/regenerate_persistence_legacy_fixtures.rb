# frozen_string_literal: true

require "tmpdir"
require "open3"
require "fileutils"
require "json"

module Hecks
  module CLI
    # The command behind `bin/regenerate_persistence_legacy_fixtures`: regenerates
    # `spec/fixtures/persistence_legacy/` through the real adapters; needs Postgres and sqlite3.
    #
    # Do not re-run it once adapters write through the state codec: it would overwrite the
    # baseline the later adapters are compared with.
    module RegeneratePersistenceLegacyFixtures
      # The scratch databases the Postgres-backed fixtures are written into.
      SCRATCH = {
        postgres:     "hecks_persistence_legacy_postgres",
        postgres_era: "hecks_persistence_legacy_postgres_era"
      }.freeze

      module_function

      # Rewrites every fixture set.
      #
      # @param root [String] the checkout whose `spec/support/persistence_legacy_fixture.rb` and
      #   fixtures are used
      # @param out [IO] where the destination goes once written
      # @return [Integer] the exit status, 0 once written
      # @raise [SystemExit] when `sqlite3 .dump` fails
      def call(root:, out: $stdout)
        require "hecks/ports/persistence/plugins/era"
        require "pg"
        require File.join(root, "spec/support/persistence_legacy_fixture")
        fixture = PersistenceLegacyFixture
        instances = fixture.instances
        write_heki(fixture, instances)
        write_sqlite(fixture, instances)
        write_d1(fixture, instances)
        with_scratch_databases do
          write_postgres(fixture, instances)
          write_postgres_era(fixture, instances)
        end
        out.puts "wrote #{fixture::DIR}"
        0
      end

      # @param fixture [Module] the fixture support module
      # @param name [String] the store's subdirectory
      # @return [String] the subdirectory, emptied and recreated
      def reset_dir(fixture, name)
        dir = File.join(fixture::DIR, name)
        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)
        dir
      end

      # @param fixture [Module] the fixture support module
      # @param relative [String] the file's path under the fixtures
      # @param value [Object] what is written, as pretty JSON
      # @return [void]
      def write_json(fixture, relative, value)
        File.write(File.join(fixture::DIR, relative), "#{JSON.pretty_generate(value)}\n")
      end

      # Creates the scratch databases for the block and drops them afterwards.
      #
      # @yield the work that needs them
      # @return [Object] whatever the block returns
      def with_scratch_databases
        admin = PG.connect(dbname: "postgres")
        admin.exec("SET client_min_messages = warning")
        SCRATCH.each_value do |name|
          admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
          admin.exec("CREATE DATABASE #{name}")
        end
        yield
      ensure
        SCRATCH.each_value { |name| admin&.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)") }
        admin&.close
      end

      # @param fixture [Module] the fixture support module
      # @param instances [Array<Object>] the fixture's instances
      # @return [void]
      def write_heki(fixture, instances)
        out = reset_dir(fixture, "heki")
        Dir.mktmpdir("hecks-legacy-heki-") do |tmp|
          instances.each do |instance|
            Hecks::Adapters::Heki.new(aggregate: instance.aggregate, settings: { dir: "." }, root: tmp).save(instance)
            %w[heki heki.journal].each do |ext|
              FileUtils.cp(File.join(tmp, "#{instance.aggregate.storage_name}.#{ext}"), out)
            end
          end
        end
      end

      # @param fixture [Module] the fixture support module
      # @param instances [Array<Object>] the fixture's instances
      # @return [void]
      # @raise [SystemExit] when `sqlite3 .dump` fails
      def write_sqlite(fixture, instances)
        out = reset_dir(fixture, "sqlite")
        Dir.mktmpdir("hecks-legacy-sqlite-") do |tmp|
          instances.each do |instance|
            Hecks::Adapters::Sqlite.new(aggregate: instance.aggregate, settings: { database: "banking.sqlite3" },
                                        root: tmp).save(instance)
          end
          dump, status = Open3.capture2("sqlite3", File.join(tmp, "banking.sqlite3"), ".dump")
          abort "sqlite3 .dump failed" unless status.success?
          File.write(File.join(out, "banking.sql"), dump)
        end
      end

      # @param fixture [Module] the fixture support module
      # @param instances [Array<Object>] the fixture's instances
      # @return [void]
      def write_d1(fixture, instances)
        reset_dir(fixture, "d1")
        connection = fixture.fake_d1_connection
        tables = instances.flat_map do |instance|
          fixture.with_d1_connection(connection) do
            Hecks::Adapters::D1.new(aggregate: instance.aggregate,
                                    settings:  { account_id: "acc", database_id: "db", api_token: "tok" }).save(instance)
          end
          [instance.aggregate.storage_name, "#{instance.aggregate.storage_name}_entries"]
        end
        rows = tables.to_h { |table| [table, connection.execute(%(SELECT * FROM "#{table}" ORDER BY rowid))] }
        write_json(fixture, "d1/rows.json", rows)
      end

      # @param fixture [Module] the fixture support module
      # @param instances [Array<Object>] the fixture's instances
      # @return [void]
      def write_postgres(fixture, instances)
        reset_dir(fixture, "postgres")
        rows = instances.to_h do |instance|
          adapter = Hecks::Adapters::Postgres.new(aggregate: instance.aggregate,
                                                  settings:  { database: SCRATCH[:postgres] })
          adapter.save(instance)
          db = adapter.instance_variable_get(:@db)
          table = PG::Connection.quote_ident(instance.aggregate.storage_name)
          entries = PG::Connection.quote_ident("#{instance.aggregate.storage_name}_entries")
          [instance.aggregate.storage_name, {
            "head"    => db.exec("SELECT * FROM #{table} ORDER BY id").to_a,
            "entries" => db.exec("SELECT aggregate_id, operation, state, mirrors FROM #{entries} ORDER BY sequence").to_a
          }]
        end
        write_json(fixture, "postgres/rows.json", rows)
      end

      # @param fixture [Module] the fixture support module
      # @param instances [Array<Object>] the fixture's instances
      # @return [void]
      def write_postgres_era(fixture, instances)
        reset_dir(fixture, "postgres_era")
        rows = instances.to_h do |instance|
          adapter = Hecks::Adapters::PostgresEra.new(aggregate: instance.aggregate,
                                                     settings:  { database: SCRATCH[:postgres_era] })
          adapter.save(instance)
          [instance.aggregate.storage_name, era_rows(adapter, instance)]
        end
        write_json(fixture, "postgres_era/rows.json", rows)
      end

      # @param adapter [Object] the `PostgresEra` adapter the instance was saved through
      # @param instance [Object] the saved instance
      # @return [Hash{String => Array}] its journal rows and its head snapshot rows
      def era_rows(adapter, instance)
        db = adapter.instance_variable_get(:@db)
        journal = adapter.instance_variable_get(:@lineage).quoted_journal
        snapshot = adapter.send(:quoted_head_snapshot)
        {
          "journal"       => db.exec_params(
            "SELECT ordinal, era, aggregate, aggregate_id, operation, state, mirrors FROM #{journal} " \
            "WHERE aggregate = $1 ORDER BY ordinal", [instance.aggregate.storage_name]
          ).to_a,
          "head_snapshot" => db.exec("SELECT id, ordinal, operation, state FROM #{snapshot} ORDER BY id").to_a
        }
      end
    end
  end
end
