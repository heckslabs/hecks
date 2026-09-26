require "open3"
require "securerandom"
require_relative "postgres_dump/connection"

module Hecks
  module Ports
    module Persistence
      # Dumps one schema of a Postgres database and proves the dump restores.
      #
      # ## What the proof is
      #
      # A dump nobody has restored is a hope. After `pg_dump` writes the file,
      # the dump is restored into a scratch database (on the source server, or on a
      # separate `verify_url` server such as the one the dump will be loaded
      # into) and every table's row count is compared with the source. That shows
      # the dump is complete and loadable. It does not re-derive current state
      # from an event journal, so a caller who needs that proves it separately.
      #
      # ## Credentials
      #
      # URLs are split by `Connection`: the password travels in the child
      # process's environment, never in `argv`.
      #
      # ## Requirements
      #
      # The `pg` gem, and `pg_dump` and `pg_restore` on `PATH` at a version no older
      # than the server's. Neither the gem nor the tools are a dependency of
      # hecks; nothing here loads until a dump is asked for.
      class PostgresDump
        # Raised for a refusal or a failed tool.
        class Error < StandardError; end

        # What a verified dump holds.
        #
        # @!attribute [r] tables
        #   @return [Hash{String => Integer}] row count of every table in the schema, by name
        Result = Struct.new(:tables, keyword_init: true)

        # @param url [String] the source database's `postgres://` URL
        # @param schema [String] the schema to dump, a plain identifier
        # @param verify_url [String, nil] the server to restore into for the proof; the source
        #   server when nil
        # @raise [Error] if `schema` is not a plain identifier or a URL is not a Postgres URL
        def initialize(url:, schema:, verify_url: nil)
          raise Error, "schema #{schema.inspect} is not a plain identifier" unless schema.to_s.match?(/\A[a-z_][a-z0-9_]*\z/i)

          @schema = schema
          @source = Connection.new(url)
          @verify = Connection.new(verify_url || url)
        end

        # Writes a custom-format dump of the schema and proves it restores.
        #
        # @param dest [String] the file to write
        # @return [Result] the verified row counts
        # @raise [Error] if the schema has no tables, a tool fails, the database refuses, or
        #   the restored counts differ from the source's
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
          "the restored dump disagrees with the source for #{detail.join(', ')}; " \
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
