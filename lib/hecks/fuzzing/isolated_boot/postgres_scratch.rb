module Hecks
  module Fuzzing
    module IsolatedBoot
      # Rebinds a copied domain to a scratch Postgres schema and prepares that schema.
      module PostgresScratch
        # Rewrites every `.hecksagon` in the copy to bind through Postgres, against this process's
        # scratch schema unless the caller names its own via `scratch:`.
        def rebind_to_postgres!(copy, database: nil, schema: nil)
          require "pg"
          database ||= FUZZ_POSTGRES_DATABASE
          schema   ||= scratch_schema(database)
          rewrite_bindings!(copy, "Postgres")
          RevisionsKept.drop!(copy)
          strip_translations!(copy)
          ensure_fuzz_schema!(database, schema)

          # One `.world` per directory a `.hecksagon` lives in, not one at the copy's
          # root — `Folder#load_domain` globs `*.world` non-recursively.
          write_worlds!(copy, "hecks_fuzz_postgres.world") { |name| postgres_world(name, database, schema) }
          write_unbound_bluebook_worlds!(copy)
        end

        def postgres_world(name, database, schema)
          <<~WORLD
            Hecks.world "#{name}" do
              default_adapter "Postgres"
              persisted_by("Postgres") do
                database "#{database}"
                schema "#{schema}"
                allow_superuser true
              end
            end
          WORLD
        end

        # Creates `database` once per process (memoized) and drops/recreates `schema`
        # inside it on every call — that's what isolates one ephemeral boot from the next.
        def ensure_fuzz_schema!(database = FUZZ_POSTGRES_DATABASE, schema = scratch_schema(database))
          # PG::Connection only closes its socket when GC finalizes it, and a tight fuzz
          # loop opens connections faster than GC reclaims them — without this, a run
          # exhausts Postgres's max_connections after a few dozen ephemeral boots.
          GC.start

          @fuzz_databases_ready ||= {}
          unless @fuzz_databases_ready[database]
            create_database_if_missing(database)
            @fuzz_databases_ready[database] = true
          end

          reset_schema!(database, schema, create: true)
        end

        # `:postgres_revision` is the only mode that exercises era/lineage-bound SQL; plain
        # `:postgres` never touches that machinery. Unlike `:postgres`, there's no shared
        # scratch constant here — `database:`/`schema:` are required keyword args because
        # the caller (`hecks quality_control sweep.run --persistence-parity`) owns that
        # database's lifecycle.
        def rebind_to_postgres_era!(copy, database:, schema:, disposable: true)
          require "pg"
          require_owned_scratch!(database, schema)

          rewrite_bindings!(copy, "Postgres")
          RevisionsKept.keep!(copy)
          ensure_postgres_era_schema!(database: database, schema: schema)

          write_worlds!(copy, "hecks_fuzz_postgres_era.world") do |name|
            postgres_era_world(name, database, schema, disposable: disposable)
          end
          write_unbound_bluebook_worlds!(copy)
        end

        # The revision layout: every hecksagon in the copy keeps its revisions, so the Postgres bind
        # boots as the revision store (ADR 0182).
        def require_owned_scratch!(database, schema)
          return unless database.to_s.empty? || schema.to_s.empty?

          raise ArgumentError,
                "adapter: :postgres_revision requires both database: and schema: — a throwaway database/schema " \
                "THIS CALLER creates and drops itself (see rebind_to_postgres_era!'s own header). " \
                "There is no shared default, unlike :postgres, so the caller cannot forget to own the lifecycle."
        end

        # The world text for one bluebook on `PostgresRevision`, in a throwaway schema the caller
        # owns.
        #
        # `allow_superuser true` is deliberate: the era write-fence is row-level security, which a
        # superuser bypasses, and the fence is not under test here.
        #
        # The ledger is disposable unless the caller holds the first era itself and wants the
        # era guard (`disposable: false`).
        def postgres_era_world(name, database, schema, disposable: true)
          <<~WORLD
            Hecks.world "#{name}" do
              default_adapter "Postgres"
              persisted_by("Postgres") do
                database "#{database}"
                schema "#{schema}"
                allow_superuser true
                #{"disposable_ledger true" if disposable}
              end
            end
          WORLD
        end

        # Mirrors `ensure_fuzz_schema!`'s GC.start-before-connecting fix for the same
        # max_connections exhaustion. Creates `database` if missing, then starts `schema` empty:
        # every ephemeral boot must see only its own rows.
        def ensure_postgres_era_schema!(database:, schema:)
          GC.start

          create_database_if_missing(database)
          reset_schema!(database, schema, create: true)
        end

        # Several pool children may reach this at once: one wins the CREATE, and the rest see the
        # database exist, or wait out the moment the template database is busy and look again.
        # Creates `schema` in `database` when it is not there yet, and keeps what it holds.
        def ensure_schema!(database, schema)
          require "pg"
          db = PG.connect(dbname: database)
          db.exec("CREATE SCHEMA IF NOT EXISTS #{db.quote_ident(schema)}")
          db.close
        end

        def create_database_if_missing(database)
          admin = PG.connect(dbname: "postgres")
          3.times do
            break if database_exists?(admin, database)

            create_database(admin, database)
          end
          admin.close
        end

        def database_exists?(admin, database)
          admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [database]).ntuples.positive?
        end

        def create_database(admin, database)
          admin.exec(%(CREATE DATABASE "#{database}"))
        rescue PG::DuplicateDatabase, PG::UniqueViolation
          nil
        rescue PG::ObjectInUse
          sleep(0.2)
        end

        # Drops `schema` from `database`, and creates it again when `create` is true.
        def reset_schema!(database, schema, create:)
          db = PG.connect(dbname: database)
          # Quiet on purpose: an ordinary DROP CASCADE NOTICEs per dropped object, which
          # would bury hecks fuzz's own output on every boot after the first.
          db.exec("SET client_min_messages = warning")
          quoted = db.quote_ident(schema)
          db.exec("DROP SCHEMA IF EXISTS #{quoted} CASCADE")
          db.exec("CREATE SCHEMA #{quoted}") if create
          db.close
        end
      end
    end
  end
end
