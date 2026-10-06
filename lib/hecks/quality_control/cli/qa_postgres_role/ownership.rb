# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaPostgresRole
      # What `sweep.create_ledger_role` hands to the role inside the database: the `public` schema,
      # its relations and its functions.
      module Ownership
        private

        def take_contents(database, role, done)
          db = PG.connect(dbname: database)
          quoted_role = db.quote_ident(role)
          take_schema(db, role, quoted_role, done)
          take_relations(db, role, quoted_role, done)
          take_functions(db, role, quoted_role, done)
          db.close
        end

        def take_schema(db, role, quoted_role, done)
          schema_owner = db.exec("SELECT pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname = 'public'")
          return unless schema_owner.ntuples.positive? && schema_owner[0]["owner"] != role

          db.exec("ALTER SCHEMA public OWNER TO #{quoted_role}")
          done << "schema public: owner #{schema_owner[0]["owner"]} -> #{role}"
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
            db.exec("ALTER #{KINDS.fetch(row["relkind"])} #{db.quote_ident(row["relname"])} OWNER TO #{quoted_role}")
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
            db.exec("ALTER FUNCTION #{db.quote_ident(row["proname"])}(#{row["args"]}) OWNER TO #{quoted_role}")
          end
          done << "#{functions.ntuples} function(s) in public -> #{role}" if functions.ntuples.positive?
        end
      end
    end
  end
end
