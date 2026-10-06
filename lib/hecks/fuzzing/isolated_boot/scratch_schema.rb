module Hecks
  module Fuzzing
    module IsolatedBoot
      # Which Postgres scratch schema a fuzz boot uses: one per pool child, so children can fuzz
      # one database at once, or the shared default for any other process.
      module ScratchSchema
        # The schema this process boots into. A pool child names its own in `FUZZ_SCHEMA_ENV`, so
        # several children can fuzz one database at once; it is dropped when the child exits.
        # Any other process shares `FUZZ_POSTGRES_SCHEMA`, which is safe only one boot at a time.
        def scratch_schema(database)
          named = ENV.fetch(FUZZ_SCHEMA_ENV, nil)
          return FUZZ_POSTGRES_SCHEMA unless named

          @fuzz_schema_cleanups ||= {}
          @fuzz_schema_cleanups[named] ||= at_exit { drop_schema_quietly(database, named) }
          named
        end

        def drop_schema_quietly(database, schema)
          reset_schema!(database, schema, create: false)
        rescue PG::Error
          nil
        end
      end
    end
  end
end
