# frozen_string_literal: true

require_relative "console_capture"

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
      # The role the QA ledger connects as when none is named.
      DEFAULT_ROLE = "hecks_qa"

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

      # Drops a database if it is there, ending other sessions on it first so a scratch database
      # left open by a crashed run does not block the drop.
      #
      # @param held [Hash] `database` (required)
      # @return [Hash{Symbol => Hash}] `report:` what happened
      # @raise [ConsoleCapture::Failure] if no database is named
      def drop_database(**held)
        database = named(held)
        with(dbname: "postgres") do |admin|
          if exists?(admin, database)
            admin.exec_params("SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
                              "WHERE datname = $1 AND pid <> pg_backend_pid()", [database])
            admin.exec("DROP DATABASE #{admin.quote_ident(database)}")
            { report: { value: "dropped database #{database}" } }
          else
            { report: { value: "no database #{database}" } }
          end
        end
      end

      private

      def named(held)
        database = plain(held[:database])
        raise ConsoleCapture::Failure, "no database named" if database.to_s.empty?

        database
      end

      def ensure_role(admin, role, done, skipped)
        found = admin.exec_params("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = $1", [role])
        if found.ntuples.zero?
          # CREATE ROLE has no IF NOT EXISTS, and concurrent creates can lose on the catalog
          # index (unique_violation) as well as on duplicate_object, so the block rescues both.
          admin.exec(<<~SQL)
            DO $$ BEGIN
              CREATE ROLE #{admin.quote_ident(role)} LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
            EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
            END $$
          SQL
          done << "created role #{role} (LOGIN, no SUPERUSER, no BYPASSRLS)"
        elsif found[0]["rolsuper"] == "t" || found[0]["rolbypassrls"] == "t"
          kind = found[0]["rolsuper"] == "t" ? "a superuser" : "a BYPASSRLS role"
          raise ConsoleCapture::Failure,
                "role #{role} already exists as #{kind}: the era write-fence cannot bind it. " \
                "Pick another role, or ALTER ROLE #{role} NOSUPERUSER NOBYPASSRLS first."
        else
          skipped << "role #{role} exists, ordinary"
        end
      end

      def hand_over_database(admin, database, role, done, skipped)
        owner = admin.exec_params(
          "SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = $1", [database]
        )
        if owner.ntuples.zero?
          raise ConsoleCapture::Failure,
                "no database #{database}: createdb it first (PostgresEra provisions every table it " \
                "needs on first connect, never the database itself)"
        elsif owner[0]["owner"] == role
          skipped << "database #{database} already owned by #{role}"
        else
          admin.exec("ALTER DATABASE #{admin.quote_ident(database)} OWNER TO #{admin.quote_ident(role)}")
          done << "database #{database}: owner #{owner[0]['owner']} -> #{role}"
        end
      end

      def hand_over_contents(db, role, done)
        quoted = db.quote_ident(role)
        schema = db.exec("SELECT pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname = 'public'")
        if schema.ntuples.positive? && schema[0]["owner"] != role
          db.exec("ALTER SCHEMA public OWNER TO #{quoted}")
          done << "schema public: owner #{schema[0]['owner']} -> #{role}"
        end

        relations = db.exec_params(<<~SQL, [role])
          SELECT c.relname, c.relkind, pg_get_userbyid(c.relowner) AS owner
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'S', 'v', 'm') AND pg_get_userbyid(c.relowner) <> $1
          ORDER BY c.relkind, c.relname
        SQL
        relations.each do |row|
          db.exec("ALTER #{KINDS.fetch(row['relkind'])} #{db.quote_ident(row['relname'])} OWNER TO #{quoted}")
        end
        done << "#{relations.ntuples} relation(s) in public -> #{role}" if relations.ntuples.positive?

        functions = db.exec_params(<<~SQL, [role])
          SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND pg_get_userbyid(p.proowner) <> $1
          ORDER BY p.proname
        SQL
        functions.each do |row|
          db.exec("ALTER FUNCTION #{db.quote_ident(row['proname'])}(#{row['args']}) OWNER TO #{quoted}")
        end
        done << "#{functions.ntuples} function(s) in public -> #{role}" if functions.ntuples.positive?
      end

      def ledger_report(database, role, done, skipped)
        lines = ["#{database} is #{role}'s"]
        done.each { |line| lines << "  did:     #{line}" }
        skipped.each { |line| lines << "  already: #{line}" }
        lines << "  bind it: database \"postgres://#{role}@localhost/#{database}\"" if done.any?
        lines.join("\n")
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
