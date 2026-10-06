require "open3"
require "securerandom"
require_relative "postgres_dump/connection"

module Hecks
  module Ports
    module Persistence
      # Dumps one schema of a Postgres database and proves the dump restores, by
      # restoring it into a scratch database and comparing every table's row count.
      class PostgresDump
        # Raised for a refusal or a failed tool.
        class Error < StandardError; end

        # What a verified dump holds: `tables` is each table's row count, by name.
        Result = Struct.new(:tables, keyword_init: true)

        # Splits `url` and `verify_url` into connections and validates `schema`.
        def initialize(url:, schema:, verify_url: nil)
          raise Error, "schema #{schema.inspect} is not a plain identifier" unless schema.to_s.match?(/\A[a-z_][a-z0-9_]*\z/i)

          @schema = schema
          @source = Connection.new(url)
          @verify = Connection.new(verify_url || url)
        end

        # Writes a custom-format dump of the schema and proves it restores.
        def call(dest)
          require "pg"
          raise Error, "schema #{@schema} has no tables in #{@source.database}" if counting(@source) { |db| counts(db) }.empty?

          run("pg_dump", @source, "--format=custom", "--no-owner", "--no-privileges", "--schema=#{@schema}", "--file=#{dest}")
          expected = counting(@source) { |db| counts(db) }
          verify_restore(dest, expected)
          Result.new(tables: expected)
        rescue PG::Error => e
          raise Error, "database error (#{e.class}): #{e.message.lines.first.to_s.strip}"
        end

        private

        def verify_restore(dump, expected)
          scratch = "dump_verify_#{Process.pid}_#{SecureRandom.hex(3)}"
          counting(@verify) do |admin|
            admin.exec("CREATE DATABASE #{admin.quote_ident(scratch)}")
            begin
              target = @verify.with_database(scratch)
              run("pg_restore", target, "--no-owner", "--no-privileges", "--exit-on-error", "--dbname=#{scratch}", dump)
              actual = counting(target) { |db| counts(db) }
              raise Error, mismatch(expected, actual) unless actual == expected
            ensure
              drop(admin, scratch)
            end
          end
        end

        def counting(connection)
          db = connection.connect
          yield db
        ensure
          db&.close
        end

        def counts(db)
          names = db.exec_params("SELECT table_name FROM information_schema.tables " \
                                 "WHERE table_schema = $1 AND table_type = 'BASE TABLE' ORDER BY 1", [@schema])
                    .map { |row| row["table_name"] }
          names.to_h do |name|
            [name, db.exec("SELECT count(*) FROM #{db.quote_ident(@schema)}.#{db.quote_ident(name)}").getvalue(0, 0).to_i]
          end
        end

        def mismatch(expected, actual)
          differing = (expected.keys | actual.keys).reject { |name| expected[name] == actual[name] }
          detail = differing.map { |name| "#{name} (source #{expected[name].inspect}, restored #{actual[name].inspect})" }
          "the restored dump disagrees with the source for #{detail.join(", ")}; " \
            "if the database took writes during the dump, dump it again"
        end

        def drop(admin, scratch)
          admin.exec("DROP DATABASE IF EXISTS #{admin.quote_ident(scratch)} WITH (FORCE)")
        rescue PG::Error => e
          warn "could not drop scratch database #{scratch} (#{e.class}); drop it by hand"
        end

        def run(tool, connection, *)
          _out, err, status = Open3.capture3(connection.env, tool, *)
          raise Error, "#{tool} failed: #{err.lines.first(3).join.strip}" unless status.success?
        rescue Errno::ENOENT
          raise Error, "#{tool} is not on PATH"
        end
      end
    end
  end
end
