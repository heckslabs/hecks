require_relative "transform_sql"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # Installs the shared `hecks_tr_*` jsonb functions that compiled translation SQL calls;
        # kept equal to the Ruby reference transform by the equivalence spec.
        module TransformInstaller
          # Installs or replaces the six `hecks_tr_*` functions under a database-wide lock.
          #
          # Locked because `CREATE OR REPLACE FUNCTION` rewrites the `pg_proc` row, so concurrent
          # boots of any two domains (the functions are global) can hit
          # `tuple concurrently updated`.
          #
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the lock or a function definition
          def install_transforms!
            nested_transaction("hecks_tr_functions") do
              @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_tr_functions'))", [])
              install_transform_functions!
            end
          end

          # Runs the six definitions without a lock; `install_transforms!` is the locked entry.
          def install_transform_functions!
            TransformSql::ALL.each { |sql| @db.exec(sql) }
          end
        end
      end
    end
  end
end
