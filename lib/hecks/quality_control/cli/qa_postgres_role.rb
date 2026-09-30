# frozen_string_literal: true

require "pg"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control create_ledger_role`: creates the ordinary Postgres
    # role the QA ledger connects as and makes it own the database. It is idempotent, and refuses a
    # superuser or `BYPASSRLS` role, which the era write-fence cannot bind.
    #
    #   hecks quality_control create_ledger_role <database> [--role <role>]   # role defaults to
    # hecks_qa
    class QaPostgresRole
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
        argv = argv.dup
        role = "hecks_qa"
        if (index = argv.index("--role"))
          role = argv[index + 1] or return usage("--role needs a name")
          argv.slice!(index, 2)
        end
        database = argv.shift
        return usage("no database named") if database.to_s.empty?
        return usage("unexpected argument #{argv.first.inspect}") unless argv.empty?

        done = []
        skipped = []
        admin = PG.connect(dbname: "postgres")
        create_role(admin, role, done, skipped)
        take_database(admin, database, role, done, skipped)
        admin.close
        take_contents(database, role, done)
        report(database, role, done, skipped)
        0
      end

      private

      def usage(message)
        @err.puts "hecks quality_control create_ledger_role: #{message}"
        @err.puts USAGE
        1
      end

      def create_role(admin, role, done, skipped)
        attrs = admin.exec_params("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = $1", [role])
        if attrs.ntuples.zero?
          # CREATE ROLE has no IF NOT EXISTS. Concurrent creates can lose on the catalog index
          # (unique_violation) rather than duplicate_object, so the block rescues both.
          admin.exec(<<~SQL)
            DO $$ BEGIN
              CREATE ROLE #{admin.quote_ident(role)} LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
            EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
            END $$
          SQL
          done << "created role #{role} (LOGIN, no SUPERUSER, no BYPASSRLS)"
        elsif attrs[0]["rolsuper"] == "t" || attrs[0]["rolbypassrls"] == "t"
          admin.close
          abort "hecks quality_control create_ledger_role: role #{role} already exists as " \
                "#{attrs[0]['rolsuper'] == 't' ? 'a superuser' : 'a BYPASSRLS role'} — the era write-fence " \
                "cannot bite it, which is the exact state this script exists to end. Pick another role, or " \
                "ALTER ROLE #{role} NOSUPERUSER NOBYPASSRLS first."
        else
          skipped << "role #{role} exists, ordinary"
        end
      end

      def take_database(admin, database, role, done, skipped)
        owner = admin.exec_params(
          "SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = $1", [database]
        )
        if owner.ntuples.zero?
          admin.close
          abort "hecks quality_control create_ledger_role: no database #{database} — createdb it first (PostgresEra provisions " \
                "every table it needs on first connect, never the database itself)"
        end
        if owner[0]["owner"] == role
          skipped << "database #{database} already owned by #{role}"
        else
          admin.exec("ALTER DATABASE #{admin.quote_ident(database)} OWNER TO #{admin.quote_ident(role)}")
          done << "database #{database}: owner #{owner[0]['owner']} -> #{role}"
        end
      end

      def take_contents(database, role, done)
        db = PG.connect(dbname: database)
        quoted_role = db.quote_ident(role)
        schema_owner = db.exec("SELECT pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname = 'public'")
        if schema_owner.ntuples.positive? && schema_owner[0]["owner"] != role
          db.exec("ALTER SCHEMA public OWNER TO #{quoted_role}")
          done << "schema public: owner #{schema_owner[0]['owner']} -> #{role}"
        end
        take_relations(db, role, quoted_role, done)
        take_functions(db, role, quoted_role, done)
        db.close
      end

      # relkind: r table, p partitioned table, S sequence, v view, m matview.
      def take_relations(db, role, quoted_role, done)
        relations = db.exec_params(<<~SQL, [role])
          SELECT c.relname, c.relkind, pg_get_userbyid(c.relowner) AS owner
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'S', 'v', 'm') AND pg_get_userbyid(c.relowner) <> $1
          ORDER BY c.relkind, c.relname
        SQL
        relations.each do |row|
          db.exec("ALTER #{KINDS.fetch(row['relkind'])} #{db.quote_ident(row['relname'])} OWNER TO #{quoted_role}")
        end
        done << "#{relations.ntuples} relation(s) in public -> #{role}" if relations.ntuples.positive?
      end

      def take_functions(db, role, quoted_role, done)
        functions = db.exec_params(<<~SQL, [role])
          SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND pg_get_userbyid(p.proowner) <> $1
          ORDER BY p.proname
        SQL
        functions.each do |row|
          db.exec("ALTER FUNCTION #{db.quote_ident(row['proname'])}(#{row['args']}) OWNER TO #{quoted_role}")
        end
        done << "#{functions.ntuples} function(s) in public -> #{role}" if functions.ntuples.positive?
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
