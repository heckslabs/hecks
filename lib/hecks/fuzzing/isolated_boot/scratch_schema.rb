module Hecks
  module Fuzzing
    module IsolatedBoot
      # Which Postgres scratch schema a fuzz boot uses: one per process, so processes can fuzz one
      # database at once without dropping a schema another process is booting into.
      module ScratchSchema
        # The schema this process boots into: the one named in `FUZZ_SCHEMA_ENV` (a sweep's pool
        # child names its own), or `FUZZ_POSTGRES_SCHEMA` suffixed with this process's pid. It is
        # dropped when the process that first asked for it exits.
        #
        # @param database [String] the scratch database the schema lives in
        # @return [String] the schema name
        def scratch_schema(database)
          schema = ENV.fetch(FUZZ_SCHEMA_ENV) { "#{FUZZ_POSTGRES_SCHEMA}_#{Process.pid}" }
          drop_at_exit(database, schema)
          schema
        end

        # Registers one drop of `schema` for when this process exits. A forked child inherits the
        # hook, so the hook drops only in the process that registered it.
        def drop_at_exit(database, schema)
          owner = Process.pid
          @fuzz_schema_cleanups ||= {}
          @fuzz_schema_cleanups[schema] ||= at_exit do
            drop_schema_quietly(database, schema) if Process.pid == owner
          end
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
