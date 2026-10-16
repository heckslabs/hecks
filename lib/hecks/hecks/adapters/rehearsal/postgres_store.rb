# frozen_string_literal: true

require "digest"
require "open3"
require "uri"
require_relative "declaration"
require_relative "postgres_reading"

module Hecks
  module Adapters
    module Rehearsal
      # The data copy as a throwaway database on the server the world's `connection_env` names.
      #
      # `empty` and `dump` create a database of this run's own (`hecks_rehearsal_<token>`) and
      # restore the dump into it; `readonly_copy` reads a database somebody else made, as it is,
      # in a read-only session, and never creates or drops one. A database is isolated, not a
      # schema, because a dump carries its own schema names. The name derives from the run key, so
      # every ask of one rehearsal reaches the same database and a dropped one is dropped once.
      class PostgresStore
        include PostgresReading

        PREFIX = "hecks_rehearsal_"
        NAME = /\A#{PREFIX}[0-9a-f]{16}\z/

        # @param declaration [Declaration] a `postgres` declaration
        # @param run [String] the rehearsal's key
        # @param protected_databases [Array<String>] databases the domain's own world names
        def initialize(declaration, run, protected_databases: [])
          @declaration = declaration
          @run = run
          @protected = protected_databases
        end

        # @return [String] the database this rehearsal reads
        def database_name
          return URI.parse(server_url).path.delete_prefix("/") if @declaration.mode == "readonly_copy"

          "#{PREFIX}#{Digest::SHA256.hexdigest(@run)[0, 16]}"
        end

        # Creates the database and restores the dump, or checks the copy is reachable. A failure
        # leaves nothing behind.
        #
        # @return [void]
        # @raise [Refused] if the server refuses, or the restore does
        def prepare!
          return reach_copy! if @declaration.mode == "readonly_copy"

          discard!
          admin { |db| db.exec("CREATE DATABASE #{db.quote_ident(database_name)}") }
          restore! if @declaration.mode == "dump"
        rescue Refused, PG::Error => e
          discard!
          raise e.is_a?(Refused) ? e : Refused.new(e.message.strip)
        end

        # Drops the throwaway database. A copy somebody else made is never dropped, and one the
        # world asked to keep is refused here, so the run records why it stands.
        #
        # @return [void]
        # @raise [Refused] if the world's `drop_after` is false and a database stands
        def drop!
          return if @declaration.mode == "readonly_copy" || !NAME.match?(database_name)
          raise Refused, "kept #{database_name}: the world's drop_after is false" unless @declaration.drop_after

          discard!
        end

        # @return [String] a URL for the database this rehearsal reads
        def url
          uri = URI.parse(server_url)
          uri.path = "/#{database_name}"
          uri.to_s
        end

        private

        def discard!
          return unless NAME.match?(database_name)

          admin { |db| db.exec("DROP DATABASE IF EXISTS #{db.quote_ident(database_name)} WITH (FORCE)") }
        rescue Refused, PG::Error
          nil
        end

        def server_url
          value = @declaration.connection
          return value if value.match?(%r{\Apostgres(ql)?://})

          raise Refused, "#{@declaration.connection_env} must hold a postgres:// URL"
        end

        def admin
          require "pg"
          db = PG.connect(server_url)
          yield db
        ensure
          db&.close
        end

        def reach_copy!
          raise Refused, "readonly_copy names a database the domain's own world persists to" if @protected.include?(url)

          admin { |db| db.exec("SELECT 1") }
        end

        # argv arrays and PG* variables: no shell, and no password on a command line.
        def restore!
          file = @declaration.dump
          raise Refused, "no such dump #{file.inspect}" unless File.file?(file)

          _out, err, status = Open3.capture3(restore_env, *restore_argv(file))
          raise Refused, "restoring the dump failed: #{err.strip.lines.first}" unless status.success?
        end

        def restore_argv(file)
          return ["psql", "--no-psqlrc", "-v", "ON_ERROR_STOP=1", "-d", database_name, "-f", file] if file.end_with?(".sql")

          ["pg_restore", "--no-owner", "--no-privileges", "-d", database_name, file]
        end

        # What the URL names, and nothing it leaves out: `postgres:///postgres` parses with an empty
        # host, which would override a `PGHOST` the environment sets and send the restore to the
        # local socket while the rest of the rehearsal reached the server by TCP.
        def restore_env
          uri = URI.parse(server_url)
          { "PGHOST" => uri.host, "PGPORT" => uri.port&.to_s, "PGUSER" => uri.user, "PGPASSWORD" => uri.password }
            .reject { |_name, value| value.to_s.empty? }
        end
      end
    end
  end
end
