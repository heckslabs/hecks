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
            install_hecks_tr_extract!
            install_hecks_tr_insert!
            install_hecks_tr_rename!
            install_hecks_tr_move!
            install_hecks_tr_convert!
            install_hecks_tr_drop!
          end

          private

          def install_hecks_tr_extract!
            @db.exec(<<~SQL)
              CREATE OR REPLACE FUNCTION hecks_tr_extract(state jsonb, path text[], OUT remaining jsonb, OUT value jsonb, OUT present boolean)
              LANGUAGE plpgsql IMMUTABLE AS $fn$
              DECLARE parent jsonb; leaf text;
              BEGIN
                remaining := state;
                present := false;
                leaf := path[array_upper(path, 1)];
                IF array_length(path, 1) = 1 THEN
                  IF state ? leaf THEN
                    present := true;
                    value := state -> leaf;
                    remaining := state - leaf;
                  END IF;
                  RETURN;
                END IF;
                parent := state #> path[1:array_upper(path, 1) - 1];
                IF jsonb_typeof(parent) = 'object' AND parent ? leaf THEN
                  present := true;
                  value := parent -> leaf;
                  parent := parent - leaf;
                  IF parent = '{}'::jsonb THEN
                    remaining := state - path[1];
                  ELSE
                    remaining := jsonb_set(state, path[1:array_upper(path, 1) - 1], parent);
                  END IF;
                END IF;
              END $fn$
            SQL
          end

          # Refuses to nest under a non-object value (such as a reference id): overwriting it would
          # be an undeclared drop. The Ruby reference transform's `insert` raises the same wording.
          def install_hecks_tr_insert!
            @db.exec(<<~SQL)
              CREATE OR REPLACE FUNCTION hecks_tr_insert(state jsonb, path text[], value jsonb, rule_label text) RETURNS jsonb
              LANGUAGE plpgsql IMMUTABLE AS $fn$
              BEGIN
                IF array_length(path, 1) = 1 THEN
                  RETURN state || jsonb_build_object(path[1], value);
                END IF;
                IF state ? path[1] AND jsonb_typeof(state -> path[1]) <> 'object' THEN
                  RAISE EXCEPTION 'cannot %: % already holds %, not a value this can nest under — moving into it would discard that value silently. Rename or drop % first.',
                    rule_label, path[1], state -> path[1], path[1];
                END IF;
                IF state -> path[1] IS NULL THEN
                  state := state || jsonb_build_object(path[1], '{}'::jsonb);
                END IF;
                RETURN jsonb_set(state, path, value);
              END $fn$
            SQL
          end

          def install_hecks_tr_rename!
            @db.exec(<<~SQL)
              CREATE OR REPLACE FUNCTION hecks_tr_rename(state jsonb, old_name text, new_name text) RETURNS jsonb
              LANGUAGE sql IMMUTABLE AS $fn$
                SELECT CASE WHEN state ? old_name
                  THEN (state - old_name) || jsonb_build_object(new_name, state -> old_name)
                  ELSE state END
              $fn$
            SQL
          end

          def install_hecks_tr_move!
            @db.exec(<<~SQL)
              CREATE OR REPLACE FUNCTION hecks_tr_move(state jsonb, from_path text[], to_path text[], rule_label text) RETURNS jsonb
              LANGUAGE plpgsql IMMUTABLE AS $fn$
              DECLARE extracted record;
              BEGIN
                SELECT * INTO extracted FROM hecks_tr_extract(state, from_path);
                IF NOT extracted.present THEN RETURN state; END IF;
                RETURN hecks_tr_insert(extracted.remaining, to_path, extracted.value, rule_label);
              END $fn$
            SQL
          end

          def install_hecks_tr_convert!
            @db.exec(<<~SQL)
              CREATE OR REPLACE FUNCTION hecks_tr_convert(state jsonb, from_path text[], to_path text[], pairs jsonb, from_label text, rule_label text) RETURNS jsonb
              LANGUAGE plpgsql IMMUTABLE AS $fn$
              DECLARE extracted record; pair jsonb;
              BEGIN
                SELECT * INTO extracted FROM hecks_tr_extract(state, from_path);
                IF NOT extracted.present THEN RETURN state; END IF;
                FOR pair IN SELECT * FROM jsonb_array_elements(pairs) LOOP
                  IF pair -> 0 = extracted.value THEN
                    RETURN hecks_tr_insert(extracted.remaining, to_path, pair -> 1, rule_label);
                  END IF;
                END LOOP;
                RAISE EXCEPTION 'cannot translate %: % has no mapping in its convert''s values: table. Add % => ... to cover it.',
                  from_label, extracted.value, extracted.value;
              END $fn$
            SQL
          end

          def install_hecks_tr_drop!
            @db.exec(<<~SQL)
              CREATE OR REPLACE FUNCTION hecks_tr_drop(state jsonb, path text[]) RETURNS jsonb
              LANGUAGE plpgsql IMMUTABLE AS $fn$
              DECLARE extracted record;
              BEGIN
                SELECT * INTO extracted FROM hecks_tr_extract(state, path);
                RETURN extracted.remaining;
              END $fn$
            SQL
          end
        end
      end
    end
  end
end
