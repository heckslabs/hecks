# frozen_string_literal: true

module Hecks
  module Adapters
    class PgAdmin
      # Makes the ledger role the owner of a database, its schema and everything in it, and says
      # what was done and what already held.
      module Ownership
        # The relations in `public` the role does not own yet.
        RELATIONS_SQL = <<~SQL
          SELECT c.relname, c.relkind, pg_get_userbyid(c.relowner) AS owner
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'S', 'v', 'm') AND pg_get_userbyid(c.relowner) <> $1
          ORDER BY c.relkind, c.relname
        SQL

        # The functions in `public` the role does not own yet.
        FUNCTIONS_SQL = <<~SQL
          SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND pg_get_userbyid(p.proowner) <> $1
          ORDER BY p.proname
        SQL

        private

        def ensure_role(admin, role, done, skipped)
          found = admin.exec_params("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = $1", [role])
          return create_role(admin, role, done) if found.ntuples.zero?

          refuse_privileged_role!(role, found[0]) if found[0]["rolsuper"] == "t" || found[0]["rolbypassrls"] == "t"
          skipped << "role #{role} exists, ordinary"
        end

        def create_role(admin, role, done)
          # CREATE ROLE has no IF NOT EXISTS, and concurrent creates can lose on the catalog
          # index (unique_violation) as well as on duplicate_object, so the block rescues both.
          admin.exec(<<~SQL)
            DO $$ BEGIN
              CREATE ROLE #{admin.quote_ident(role)} LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
            EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
            END $$
          SQL
          done << "created role #{role} (LOGIN, no SUPERUSER, no BYPASSRLS)"
        end

        def refuse_privileged_role!(role, found)
          kind = found["rolsuper"] == "t" ? "a superuser" : "a BYPASSRLS role"
          raise ConsoleCapture::Failure,
                "role #{role} already exists as #{kind}: the era write-fence cannot bind it. " \
                "Pick another role, or ALTER ROLE #{role} NOSUPERUSER NOBYPASSRLS first."
        end

        def hand_over_database(admin, database, role, done, skipped)
          owner = admin.exec_params(
            "SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = $1", [database]
          )
          refuse_missing_database!(database) if owner.ntuples.zero?
          if owner[0]["owner"] == role
            skipped << "database #{database} already owned by #{role}"
          else
            admin.exec("ALTER DATABASE #{admin.quote_ident(database)} OWNER TO #{admin.quote_ident(role)}")
            done << "database #{database}: owner #{owner[0]["owner"]} -> #{role}"
          end
        end

        def refuse_missing_database!(database)
          raise ConsoleCapture::Failure,
                "no database #{database}: createdb it first (PostgresEra provisions every table it " \
                "needs on first connect, never the database itself)"
        end

        def hand_over_contents(db, role, done)
          hand_over_schema(db, role, done)
          hand_over_relations(db, role, done)
          hand_over_functions(db, role, done)
        end

        def hand_over_schema(db, role, done)
          schema = db.exec("SELECT pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname = 'public'")
          return unless schema.ntuples.positive? && schema[0]["owner"] != role

          db.exec("ALTER SCHEMA public OWNER TO #{db.quote_ident(role)}")
          done << "schema public: owner #{schema[0]["owner"]} -> #{role}"
        end

        def hand_over_relations(db, role, done)
          quoted = db.quote_ident(role)
          relations = db.exec_params(RELATIONS_SQL, [role])
          relations.each do |row|
            db.exec("ALTER #{KINDS.fetch(row["relkind"])} #{db.quote_ident(row["relname"])} OWNER TO #{quoted}")
          end
          done << "#{relations.ntuples} relation(s) in public -> #{role}" if relations.ntuples.positive?
        end

        def hand_over_functions(db, role, done)
          quoted = db.quote_ident(role)
          functions = db.exec_params(FUNCTIONS_SQL, [role])
          functions.each do |row|
            db.exec("ALTER FUNCTION #{db.quote_ident(row["proname"])}(#{row["args"]}) OWNER TO #{quoted}")
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
      end
    end
  end
end
