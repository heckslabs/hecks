# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

module Hecks
  module PersistenceLegacyFixture
    # Regenerates the persistence legacy fixtures by writing the seed records through the real
    # adapters: Heki, SQLite, D1, Postgres and PostgresEra. It needs a reachable Postgres (which
    # scratch databases are made in) and the `sqlite3` program (which dumps the SQLite database).
    #
    # The fixtures are the baseline later adapters are compared with, so a caller confirms before
    # this is run, and it is not re-run once adapters write through the state codec: it would
    # overwrite the baseline.
    class Regenerate
      # The scratch database each Postgres-backed store is written to.
      SCRATCH = {
        postgres:     "hecks_persistence_legacy_postgres",
        postgres_era: "hecks_persistence_legacy_postgres_era"
      }.freeze

      # Raised when a fixture cannot be written.
      class Failure < StandardError; end

      # Rewrites every fixture set.
      #
      # @param dir [String] where the fixtures stand
      # @return [String] `wrote <dir>`
      # @raise [Failure] when the `sqlite3` dump fails
      def self.call(dir: PersistenceLegacyFixture::DIR)
        new(dir).call
      end

      # @param dir [String] where the fixtures stand
      def initialize(dir)
        @dir = dir
      end

      # @return [String] `wrote <dir>`
      def call
        require "hecks/ports/persistence/plugins/era"
        require "pg"
        instances = PersistenceLegacyFixture.instances
        write_heki(instances)
        write_sqlite(instances)
        write_d1(instances)
        with_scratch_databases do
          write_postgres(instances)
          write_postgres_era(instances)
        end
        "wrote #{@dir}"
      end

      private

      def reset_dir(name)
        dir = File.join(@dir, name)
        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)
        dir
      end

      def write_json(relative, value)
        File.write(File.join(@dir, relative), "#{JSON.pretty_generate(value)}\n")
      end

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

      def write_heki(instances)
        out = reset_dir("heki")
        Dir.mktmpdir("hecks-legacy-heki-") do |tmp|
          instances.each do |instance|
            Hecks::Adapters::Heki.new(aggregate: instance.aggregate, settings: { dir: "." }, root: tmp).save(instance)
            %w[heki heki.journal].each do |ext|
              FileUtils.cp(File.join(tmp, "#{instance.aggregate.storage_name}.#{ext}"), out)
            end
          end
        end
      end

      def write_sqlite(instances)
        out = reset_dir("sqlite")
        Dir.mktmpdir("hecks-legacy-sqlite-") do |tmp|
          instances.each do |instance|
            Hecks::Adapters::Sqlite.new(aggregate: instance.aggregate, settings: { database: "banking.sqlite3" },
                                        root: tmp).save(instance)
          end
          dump, status = Open3.capture2("sqlite3", File.join(tmp, "banking.sqlite3"), ".dump")
          raise Failure, "sqlite3 .dump failed" unless status.success?

          File.write(File.join(out, "banking.sql"), dump)
        end
      end

      def write_d1(instances)
        reset_dir("d1")
        connection = PersistenceLegacyFixture.fake_d1_connection
        tables = instances.flat_map do |instance|
          PersistenceLegacyFixture.with_d1_connection(connection) do
            Hecks::Adapters::D1.new(aggregate: instance.aggregate,
                                    settings:  { account_id: "acc", database_id: "db", api_token: "tok" }).save(instance)
          end
          [instance.aggregate.storage_name, "#{instance.aggregate.storage_name}_entries"]
        end
        write_json("d1/rows.json",
                   tables.to_h { |table| [table, connection.execute(%(SELECT * FROM "#{table}" ORDER BY rowid))] })
      end

      def write_postgres(instances)
        reset_dir("postgres")
        rows = instances.to_h do |instance|
          adapter = Hecks::Adapters::Postgres.new(aggregate: instance.aggregate, settings: { database: SCRATCH[:postgres] })
          adapter.save(instance)
          db = adapter.instance_variable_get(:@db)
          table = PG::Connection.quote_ident(instance.aggregate.storage_name)
          entries = PG::Connection.quote_ident("#{instance.aggregate.storage_name}_entries")
          [instance.aggregate.storage_name, {
            "head"    => db.exec("SELECT * FROM #{table} ORDER BY id").to_a,
            "entries" => db.exec("SELECT aggregate_id, operation, state, mirrors FROM #{entries} ORDER BY sequence").to_a
          }]
        end
        write_json("postgres/rows.json", rows)
      end

      def write_postgres_era(instances)
        reset_dir("postgres_era")
        rows = instances.to_h { |instance| [instance.aggregate.storage_name, era_rows(instance)] }
        write_json("postgres_era/rows.json", rows)
      end

      def era_rows(instance)
        adapter = Hecks::Adapters::PostgresEra.new(aggregate: instance.aggregate,
                                                   settings:  { database: SCRATCH[:postgres_era] })
        adapter.save(instance)
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
