# frozen_string_literal: true

module Hecks
  module PersistenceLegacyFixture
    class Regenerate
      # Writing the Postgres and PostgresEra fixtures through scratch databases, which are made
      # for the run and dropped after it. Included in `Regenerate`.
      module PostgresStores
        # The scratch database each Postgres-backed store is written to.
        SCRATCH = {
          postgres:     "hecks_persistence_legacy_postgres",
          postgres_era: "hecks_persistence_legacy_postgres_era"
        }.freeze

        private

        def with_scratch_databases
          admin = PG.connect(dbname: "postgres")
          admin.exec("SET client_min_messages = warning")
          SCRATCH.each_value { |name| recreate_database(admin, name) }
          yield
        ensure
          SCRATCH.each_value { |name| admin&.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)") }
          admin&.close
        end

        def recreate_database(admin, name)
          admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
          admin.exec("CREATE DATABASE #{name}")
        end

        def write_postgres(instances)
          reset_dir("postgres")
          write_json("postgres/rows.json", instances.to_h { |instance| postgres_rows(instance) })
        end

        def postgres_rows(instance)
          adapter = Hecks::Adapters::Postgres.new(aggregate: instance.aggregate, settings: { database: SCRATCH[:postgres] })
          adapter.save(instance)
          name = instance.aggregate.storage_name
          [name, stored_rows(adapter.instance_variable_get(:@db), name)]
        end

        def stored_rows(db, name)
          table = PG::Connection.quote_ident(name)
          entries = PG::Connection.quote_ident("#{name}_entries")
          {
            "head"    => db.exec("SELECT * FROM #{table} ORDER BY id").to_a,
            "entries" => db.exec("SELECT aggregate_id, operation, state, mirrors FROM #{entries} ORDER BY sequence").to_a
          }
        end

        def write_postgres_era(instances)
          reset_dir("postgres_era")
          rows = instances.to_h { |instance| [instance.aggregate.storage_name, era_rows(instance)] }
          write_json("postgres_era/rows.json", rows)
        end

        def era_rows(instance)
          adapter = Hecks::Adapters::PostgresEra.new(aggregate: instance.aggregate,
                                                     settings:  { database: SCRATCH[:postgres_era] })
          adapter.save(instance)
          db = adapter.instance_variable_get(:@db)
          snapshot = adapter.send(:quoted_head_snapshot)
          {
            "journal"       => journal_rows(db, adapter.instance_variable_get(:@lineage).quoted_journal,
                                            instance.aggregate.storage_name),
            "head_snapshot" => db.exec("SELECT id, ordinal, operation, state FROM #{snapshot} ORDER BY id").to_a
          }
        end

        def journal_rows(db, journal, name)
          db.exec_params(
            "SELECT ordinal, era, aggregate, aggregate_id, operation, state, mirrors FROM #{journal} " \
            "WHERE aggregate = $1 ORDER BY ordinal", [name]
          ).to_a
        end
      end
    end
  end
end
