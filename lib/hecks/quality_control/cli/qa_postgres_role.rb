# frozen_string_literal: true

require "pg"
require_relative "qa_postgres_role/ownership"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control sweep.create_ledger_role`: creates the ordinary
    # Postgres role the QA ledger connects as and makes it own the database. It is idempotent, and
    # refuses a superuser or `BYPASSRLS` role, which the era write-fence cannot bind.
    #
    #   hecks quality_control sweep.create_ledger_role <database> [--role <role>]   # role defaults
    # to hecks_qa
    class QaPostgresRole
      include Ownership

      USAGE = "usage: hecks quality_control create_ledger_role <database> [--role <role>]"

      # `relkind` of each relation to the word `ALTER` takes for it. Partitions are their own
      # rows; `ALTER TABLE ... OWNER` on the parent does not recurse.
      KINDS = { "r" => "TABLE", "p" => "TABLE", "S" => "SEQUENCE", "v" => "VIEW", "m" => "MATERIALIZED VIEW" }.freeze

      # Creates the role and hands it the database.
      #
      # @param argv [Array<String>] the database, and optionally `--role NAME`
      # @param out [IO] where the report goes
      # @param err [IO] where a usage error goes
      # @return [Integer] 0 once the database is the role's, 1 for a usage error
      # @raise [SystemExit] when the role is a superuser or `BYPASSRLS`, or the database is missing
      def self.call(argv, out: $stdout, err: $stderr)
        new(out: out, err: err).call(argv)
      end

      # @param out [IO] where the report goes
      # @param err [IO] where a usage error goes
      def initialize(out: $stdout, err: $stderr)
        @out = out
        @err = err
      end

      # @param argv [Array<String>] the database, and optionally `--role NAME`
      # @return [Integer] the exit status
      # @raise [SystemExit] when the role is a superuser or `BYPASSRLS`, or the database is missing
      def call(argv)
        database, role = parse(argv.dup)
        provision(database, role)
        0
      rescue UsageError => e
        usage(e.message)
      end

      private

      # Raised for a wrong command line; `call` answers it with the usage line and status 1.
      class UsageError < StandardError; end

      def parse(argv)
        role = take_role(argv)
        database = argv.shift
        raise UsageError, "no database named" if database.to_s.empty?
        raise UsageError, "unexpected argument #{argv.first.inspect}" unless argv.empty?

        [database, role]
      end

      def take_role(argv)
        index = argv.index("--role")
        return "hecks_qa" unless index

        role = argv[index + 1]
        raise UsageError, "--role needs a name" unless role

        argv.slice!(index, 2)
        role
      end

      def provision(database, role)
        done = []
        skipped = []
        admin = PG.connect(dbname: "postgres")
        create_role(admin, role, done, skipped)
        take_database(admin, database, role, done, skipped)
        admin.close
        take_contents(database, role, done)
        report(database, role, done, skipped)
      end

      def usage(message)
        @err.puts "hecks quality_control create_ledger_role: #{message}"
        @err.puts USAGE
        1
      end

      def create_role(admin, role, done, skipped)
        attrs = admin.exec_params("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = $1", [role])
        if attrs.ntuples.zero?
          insert_role(admin, role)
          done << "created role #{role} (LOGIN, no SUPERUSER, no BYPASSRLS)"
        elsif attrs[0]["rolsuper"] == "t" || attrs[0]["rolbypassrls"] == "t"
          refuse_privileged_role(admin, role, attrs[0])
        else
          skipped << "role #{role} exists, ordinary"
        end
      end

      # CREATE ROLE has no IF NOT EXISTS. Concurrent creates can lose on the catalog index
      # (unique_violation) rather than duplicate_object, so the block rescues both.
      def insert_role(admin, role)
        admin.exec(<<~SQL)
          DO $$ BEGIN
            CREATE ROLE #{admin.quote_ident(role)} LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
          EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
          END $$
        SQL
      end

      def refuse_privileged_role(admin, role, attrs)
        admin.close
        abort "hecks quality_control create_ledger_role: role #{role} already exists as " \
              "#{attrs["rolsuper"] == "t" ? "a superuser" : "a BYPASSRLS role"} — the era write-fence " \
              "cannot bite it, which is the exact state this script exists to end. Pick another role, or " \
              "ALTER ROLE #{role} NOSUPERUSER NOBYPASSRLS first."
      end

      def take_database(admin, database, role, done, skipped)
        owner = database_owner(admin, database)
        if owner == role
          skipped << "database #{database} already owned by #{role}"
        else
          admin.exec("ALTER DATABASE #{admin.quote_ident(database)} OWNER TO #{admin.quote_ident(role)}")
          done << "database #{database}: owner #{owner} -> #{role}"
        end
      end

      def database_owner(admin, database)
        rows = admin.exec_params(
          "SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = $1", [database]
        )
        return rows[0]["owner"] unless rows.ntuples.zero?

        admin.close
        abort "hecks quality_control create_ledger_role: no database #{database} — createdb it first (PostgresEra provisions " \
              "every table it needs on first connect, never the database itself)"
      end

      def report(database, role, done, skipped)
        @out.puts "hecks quality_control create_ledger_role: #{database} is #{role}'s"
        done.each { |line| @out.puts "  did:     #{line}" }
        skipped.each { |line| @out.puts "  already: #{line}" }
        @out.puts "  bind it: database \"postgres://#{role}@localhost/#{database}\"" if done.any?
      end
    end
  end
end
