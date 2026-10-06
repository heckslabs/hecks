require "fileutils"
require "tmpdir"
require_relative "../isolated_boot"

module Hecks
  module Fuzzing
    module ConcurrentDispatch
      # Copies a target domain, rebinds it to a shared `PostgresEra` schema and boots it there.
      module WorldCopy
        FUZZ_WORLD_FILE = "hecks_fuzz_postgres_era.world".freeze

        # Same copy-and-rebind IsolatedBoot.call(..., adapter: :postgres_era) does,
        # minus the schema wipe — this schema already holds what setup wrote, and
        # the race must run against that, not a blank one.
        def boot_preserving_schema(domain_path, database:, schema:)
          Dir.mktmpdir("hecks-concurrency") do |tmp|
            copy = File.join(tmp, File.basename(domain_path))
            IsolatedBoot.copy_dereferencing(domain_path, copy)
            FileUtils.rm_rf(File.join(copy, "data"))
            IsolatedBoot.rewrite_bindings!(copy, "PostgresEra")
            write_postgres_era_world!(copy, database: database, schema: schema)
            yield copy
          end
        end

        # One world file per directory, merging every hecksagon name found there,
        # replacing any other `.world` file the copy already carries.
        def write_postgres_era_world!(copy, database:, schema:)
          hecksagon_names_by_dir(copy).each do |dir, names|
            names = names.uniq
            next if names.empty?

            worlds = names.map { |name| postgres_era_world(name, database, schema) }
            File.write(File.join(dir, FUZZ_WORLD_FILE), worlds.join("\n"))
          end

          Dir.glob(File.join(copy, "**", "*.world")).each do |path|
            File.delete(path) unless File.basename(path) == FUZZ_WORLD_FILE
          end
        end

        # The `Hecks.hecksagon` names each directory under `copy` declares.
        def hecksagon_names_by_dir(copy)
          worlds_by_dir = Hash.new { |h, k| h[k] = [] }
          Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |hecksagon_path|
            names = File.read(hecksagon_path).scan(/Hecks\.hecksagon\s+"([^"]+)"/).flatten
            worlds_by_dir[File.dirname(hecksagon_path)].concat(names)
          end
          worlds_by_dir
        end

        def postgres_era_world(name, database, schema)
          <<~WORLD
            Hecks.world "#{name}" do
              persisted_by("PostgresEra") do
                database "#{database}"
                schema "#{schema}"
                allow_superuser true
              end
            end
          WORLD
        end
      end
    end
  end
end
