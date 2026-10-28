module Hecks
  module Fuzzing
    module ProjectionAgreement
      # Binds every bluebook of a copied, Memory-bound domain `projected_by` one projection
      # adapter, by writing a hecksagon and a world beside each directory's own, which the
      # registry merges into them.
      module Binding
        # The files written into each directory that holds a hecksagon.
        HECKSAGON_FILE = "hecks_fuzz_projection.hecksagon".freeze
        WORLD_FILE = "hecks_fuzz_projection.world".freeze

        module_function

        # @param copy [String] the copied domain's root, already rebound to Memory
        # @param projection [Symbol] a key of `ProjectionAgreement::ADAPTERS`
        # @param scratch [Hash] the Postgres projection's `database:` and `schema:`
        # @return [void]
        # @raise [ArgumentError] if `projection` names no projection adapter
        def bind!(copy, projection, **scratch)
          adapter = ADAPTERS.fetch(projection) do
            raise ArgumentError, "no projection for #{projection.inspect} — :sqlite or :postgres"
          end
          settings = settings_for(copy, projection, **scratch)
          IsolatedBoot.hecksagon_names_by_dir(copy).each do |dir, names|
            write!(dir, names.uniq, adapter, settings) unless names.empty?
          end
        end

        def write!(dir, names, adapter, settings)
          File.write(File.join(dir, HECKSAGON_FILE), names.map { |name| hecksagon(name, adapter) }.join("\n"))
          File.write(File.join(dir, WORLD_FILE), names.map { |name| world(name, adapter, settings) }.join("\n"))
        end

        def hecksagon(name, adapter) = %(Hecks.hecksagon "#{name}" do\n  projected_by "#{adapter}"\nend\n)

        def world(name, adapter, settings)
          lines = settings.map { |key, value| %(    #{key} "#{value}"\n) }.join
          %(Hecks.world "#{name}" do\n  projected_by("#{adapter}") do\n#{lines}  end\nend\n)
        end

        # SQLite projects into one file inside the copy; Postgres into a scratch schema of its
        # own, dropped and recreated here so one boot starts from an empty read store.
        def settings_for(copy, projection, database: nil, schema: nil)
          return { database: File.join(copy, "data", "hecks_fuzz_projection.sqlite3") } if projection == :sqlite

          require "pg"
          database ||= IsolatedBoot::FUZZ_POSTGRES_DATABASE
          schema ||= scratch_schema(database)
          IsolatedBoot.ensure_fuzz_schema!(database, schema)
          { database: database, schema: schema }
        end

        # Beside the process's own scratch schema, and dropped when the process exits, as its
        # persistence schema is.
        def scratch_schema(database)
          schema = "#{IsolatedBoot.scratch_schema(database)}_projection"
          IsolatedBoot.drop_at_exit(database, schema)
          schema
        end
      end
    end
  end
end
