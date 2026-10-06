# frozen_string_literal: true

require "uri"
require_relative "console_capture"
require_relative "pg_admin/ownership"

module Hecks
  module Adapters
    # The `PgAdmin` port's adapter: the Postgres administration that happens outside the
    # persistence adapters, namely roles and scratch databases.
    #
    # Connections are made to the maintenance database (`postgres`) or to the database being
    # administered, as the current operating-system user, exactly as `psql` would. Nothing here
    # creates the ledger database itself: PostgresEra provisions the tables it needs on first
    # connect, and an operator makes the database with `createdb`.
    class PgAdmin
      include Ownership

      # The role the QA ledger connects as when none is named.
      DEFAULT_ROLE = "hecks_qa"

      # What every database this adapter drops must start with, and be followed by a name.
      SCRATCH = /\Ascratch_\w+\z/

      # Databases that are never dropped, whatever their name: the maintenance and template
      # databases.
      SYSTEM_DATABASES = %w[postgres template0 template1].freeze

      # The environment variables that name the ledger or production database in use.
      CONFIGURED_DATABASES = %w[PGDATABASE HECKS_LEDGER_DATABASE HECKS_DATABASE].freeze

      # Relation kinds in `pg_class` mapped to the `ALTER` keyword that changes their owner.
      # Partitions are their own rows, so `ALTER TABLE ... OWNER` on a parent does not reach them.
      KINDS = { "r" => "TABLE", "p" => "TABLE", "S" => "SEQUENCE", "v" => "VIEW",
                "m" => "MATERIALIZED VIEW" }.freeze

      class << self
        # @return [#call, nil] opens a connection given `dbname:` and answers an object with
        #   `exec`, `exec_params`, `quote_ident` and `close`; a spec replaces it so no server is
        #   reached. The `pg` gem is required only when this is nil.
        attr_accessor :connector
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Creates the ordinary role the QA ledger connects as and makes it own the database, its
      # schema, and everything in it. Safe to repeat: what is already right is reported, not redone.
      #
      # A superuser or BYPASSRLS role is refused, because the era write-fence cannot bind it.
      #
      # @param held [Hash] `database` (required) and `role` (`hecks_qa` when absent)
      # @return [Hash{Symbol => Hash}] `report:` what was done and what already held
      # @raise [ConsoleCapture::Failure] if no database is named or it does not exist, or the role
      #   exists with privileges the fence cannot bind
      def create_ledger_role(**held)
        database = named(held)
        role = plain(held[:role]) || DEFAULT_ROLE

        done = []
        skipped = []
        with(dbname: "postgres") do |admin|
          ensure_role(admin, role, done, skipped)
          hand_over_database(admin, database, role, done, skipped)
        end
        with(dbname: database) { |db| hand_over_contents(db, role, done) }

        { report: { value: ledger_report(database, role, done, skipped) } }
      end

      # Creates an empty database, for a scratch run that needs one. Repeating it reports that the
      # database exists.
      #
      # @param held [Hash] `database` (required)
      # @return [Hash{Symbol => Hash}] `report:` what happened
      # @raise [ConsoleCapture::Failure] if no database is named
      def create_database(**held)
        database = named(held)
        with(dbname: "postgres") do |admin|
          if exists?(admin, database)
            { report: { value: "database #{database} already exists" } }
          else
            admin.exec("CREATE DATABASE #{admin.quote_ident(database)}")
            { report: { value: "created database #{database}" } }
          end
        end
      end

      # Drops a scratch database if it is there, ending other sessions on it first so one left
      # open by a crashed run does not block the drop. Ending every session on a database is
      # only safe for a throwaway one, so a name must start with `scratch_` and must not be the
      # ledger or production database the environment names.
      #
      # @param held [Hash] `database` (required)
      # @return [Hash{Symbol => Hash}] `report:` what happened
      # @raise [ConsoleCapture::Failure] if no database is named, it is not a scratch name, or it
      #   is a configured ledger or production database
      def drop_database(**held)
        database = named(held)
        refuse_to_drop!(database)
        with(dbname: "postgres") { |admin| drop_if_exists(admin, database) }
      end

      private

      # Ends the sessions on the database and drops it, or reports that it is not there.
      def drop_if_exists(admin, database)
        return { report: { value: "no database #{database}" } } unless exists?(admin, database)

        admin.exec_params("SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
                          "WHERE datname = $1 AND pid <> pg_backend_pid()", [database])
        admin.exec("DROP DATABASE #{admin.quote_ident(database)}")
        { report: { value: "dropped database #{database}" } }
      end

      def refuse_to_drop!(database)
        if SYSTEM_DATABASES.include?(database.downcase) || configured_databases.include?(database)
          raise ConsoleCapture::Failure, "refusing to drop #{database}: it is the ledger, production or " \
                                         "a system database"
        end
        return if database.match?(SCRATCH)

        raise ConsoleCapture::Failure, "refusing to drop #{database}: only databases named scratch_<name> " \
                                       "are dropped"
      end

      def configured_databases
        named = CONFIGURED_DATABASES.filter_map { |variable| ENV.fetch(variable, nil) }
        url = ENV.fetch("DATABASE_URL", nil)
        named << URI.parse(url).path.to_s.delete_prefix("/") if url && !url.empty?
        named.reject(&:empty?)
      rescue URI::InvalidURIError
        named
      end

      def named(held)
        database = plain(held[:database])
        raise ConsoleCapture::Failure, "no database named" if database.to_s.empty?

        database
      end

      def exists?(admin, database)
        admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [database]).ntuples.positive?
      end

      def with(dbname:)
        connection = connect(dbname)
        yield connection
      rescue ConsoleCapture::Failure
        raise
      rescue StandardError => e
        raise ConsoleCapture::Failure, "postgres: #{e.message.strip}"
      ensure
        connection&.close
      end

      def connect(dbname)
        return self.class.connector.call(dbname: dbname) if self.class.connector

        require "pg"
        PG.connect(dbname: dbname)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
