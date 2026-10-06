# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "postgres_stores"

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
      include PostgresStores

      # The scratch database each Postgres-backed store is written to.
      SCRATCH = PostgresStores::SCRATCH

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
        write_file_stores(instances)
        with_scratch_databases do
          write_postgres(instances)
          write_postgres_era(instances)
        end
        "wrote #{@dir}"
      end

      private

      def write_file_stores(instances)
        write_heki(instances)
        write_sqlite(instances)
        write_d1(instances)
      end

      def reset_dir(name)
        dir = File.join(@dir, name)
        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)
        dir
      end

      def write_json(relative, value)
        File.write(File.join(@dir, relative), "#{JSON.pretty_generate(value)}\n")
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
          File.write(File.join(out, "banking.sql"), sqlite_dump(File.join(tmp, "banking.sqlite3")))
        end
      end

      def sqlite_dump(database)
        dump, status = Open3.capture2("sqlite3", database, ".dump")
        raise Failure, "sqlite3 .dump failed" unless status.success?

        dump
      end

      def write_d1(instances)
        reset_dir("d1")
        connection = PersistenceLegacyFixture.fake_d1_connection
        tables = instances.flat_map { |instance| save_to_d1(instance, connection) }
        write_json("d1/rows.json",
                   tables.to_h { |table| [table, connection.execute(%(SELECT * FROM "#{table}" ORDER BY rowid))] })
      end

      # @return [Array<String>] the tables the instance's aggregate is stored in
      def save_to_d1(instance, connection)
        PersistenceLegacyFixture.with_d1_connection(connection) do
          Hecks::Adapters::D1.new(aggregate: instance.aggregate,
                                  settings:  { account_id: "acc", database_id: "db", api_token: "tok" }).save(instance)
        end
        [instance.aggregate.storage_name, "#{instance.aggregate.storage_name}_entries"]
      end
    end
  end
end
