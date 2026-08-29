module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # Installs the shared, domain-independent `hecks_tr_*` Postgres
        # functions (extract/insert/rename/move/convert/drop over jsonb)
        # that a compiled translation rule set's SQL calls into — the SQL
        # compilation target kept equal to the Ruby reference transform by
        # the cross-execution equivalence spec, never a second source of
        # truth.
        module TransformInstaller
          # The jsonb rule transforms — installed once, idempotently. Kept
          # equal to the port's reference entry-JSON transform by the
          # cross-execution equivalence spec; the SQL here is a compilation
          # target, not a second source of truth.
          #
          # LOCKED, unlike every other statement `ensure_base!` runs — those
          # are all `CREATE ... IF NOT EXISTS`/`ADD COLUMN IF NOT EXISTS`,
          # which Postgres itself resolves safely under concurrent boots.
          # `CREATE OR REPLACE FUNCTION` is not: it always rewrites the
          # `pg_proc` row, so two sessions racing to (re)install the SAME
          # function — these six are shared/global, not per-domain, so any
          # two domains' concurrent first-boots can collide here — hit a
          # real `PG::InternalError: tuple concurrently updated`, not a
          # graceful no-op. `nested_transaction` is the same
          # already-open-transaction-safe wrapper `ensure_field_cache!`
          # uses for its own advisory lock; a fixed, domain-independent key
          # is correct since these functions have no domain of their own.
          def install_transforms!
            nested_transaction("hecks_tr_functions") do
              @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_tr_functions'))", [])
              install_transform_functions!
            end
          end

          # Six independent CREATE OR REPLACE FUNCTION statements — each
          # self-contained SQL, no shared Ruby state, and (per this
          # module's own header comment) safe in any install order since
          # plpgsql bodies aren't resolved against each other until
          # called, not at CREATE time. Split one-per-function below
          # purely so each has its own name and (where relevant) its own
          # comment to sit next to, not because the six have any
          # sequencing dependency on one another.
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

          # ADVERSARIAL FINDING: a destination whose top segment already
          # holds a value — most commonly a reference, a bare scalar id
          # — used to be silently overwritten with an empty object the
          # moment a dotted destination needed to nest under it. That is
          # a drop that never declared itself, the one thing this
          # language exists to make explicit (see hecks_tr_convert's own
          # refusal below, the same shape) — refused here instead, with
          # the Ruby reference transform (ports/persistence/lineage.rb's
          # `insert`) raising the identical wording.
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
