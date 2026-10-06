module Hecks
  module Fuzzing
    module IsolatedBoot
      # Rewrites the `.hecksagon` bindings and `.world` files of a copied domain.
      module Worlds
        # The name of a `Hecks.hecksagon` block.
        HECKSAGON_NAME = /Hecks\.hecksagon\s+"([^"]+)"/

        # The name of a `Hecks.bluebook` block.
        BLUEBOOK_NAME = /Hecks\.bluebook[\s(]+"([^"]+)"/

        # Replaces every `.world` in the copy with one that declares only `default_adapter`,
        # so an aggregate left unbound by its hecksagon still falls back to `adapter_name`.
        def write_default_worlds!(copy, adapter_name)
          write_worlds!(copy, "hecks_fuzz_default.world") do |name|
            <<~WORLD
              Hecks.world "#{name}" do
                default_adapter "#{adapter_name}"
              end
            WORLD
          end
        end

        # Gives every chapter with no hecksagon block (so no bind) a world of its own that
        # falls back to Memory, since the worlds `write_worlds!` wrote require a database
        # a chapter with no bind can't provide.
        def write_unbound_chapter_worlds!(copy)
          named = Dir.glob(File.join(copy, "**", "*.hecksagon")).flat_map { |path| hecksagon_names_in(path) }
          bluebooks = Dir.glob(File.join(copy, "**", "*.bluebook")).group_by { |path| File.dirname(path) }
          bluebooks.each do |dir, files|
            unbound = unbound_names(files, named)
            named.concat(unbound)
            write_unbound_world(dir, unbound) unless unbound.empty?
          end
        end

        # The bluebook names `files` declare that `named` does not already cover.
        def unbound_names(files, named)
          files.flat_map { |path| File.read(path).scan(BLUEBOOK_NAME).flatten }.uniq - named
        end

        # Writes `dir`'s one world file falling every `unbound` chapter back to Memory.
        def write_unbound_world(dir, unbound)
          worlds = unbound.map { |name| %(Hecks.world "#{name}" do\n  default_adapter "Memory"\nend\n) }
          File.write(File.join(dir, "hecks_fuzz_unbound.world"), worlds.join("\n"))
        end

        # Writes one `.world` per directory holding a `.hecksagon`, naming every
        # `Hecks.hecksagon` block found there, and deletes every other `.world` in the
        # copy. One write per directory, not per file — a domain can split hecksagon
        # blocks (e.g. `context_map.hecksagon` beside the main one) across sibling files
        # in the same directory, and a second `File.write` to the same path would drop
        # the first file's names.
        def write_worlds!(copy, world_file, &world_for)
          hecksagon_names_by_dir(copy).each do |dir, names|
            next if names.empty?

            File.write(File.join(dir, world_file), names.uniq.map(&world_for).join("\n"))
          end

          Dir.glob(File.join(copy, "**", "*.world")).each do |path|
            File.delete(path) unless File.basename(path) == world_file
          end
        end

        # The `Hecks.hecksagon` names declared in each directory under `copy`.
        def hecksagon_names_by_dir(copy)
          names_by_dir = Hash.new { |hash, dir| hash[dir] = [] }
          Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |hecksagon_path|
            names_by_dir[File.dirname(hecksagon_path)].concat(hecksagon_names_in(hecksagon_path))
          end
          names_by_dir
        end

        def hecksagon_names_in(path) = File.read(path).scan(HECKSAGON_NAME).flatten

        # Deletes every `translations/*.bluebook` in the copy. A compute/rekey translation
        # edge refuses to boot under any non-lineage-capable adapter (only `PostgresEra`
        # answers `lineage_capable? == true`), so every other mode strips it here rather
        # than tripping that refusal. Safe to drop: an ephemeral, zero-history boot never
        # has a pre-existing era-1 row to translate — the edge only matters at mint time,
        # against a real database, never here.
        def strip_translations!(copy)
          Dir.glob(File.join(copy, "**", "translations", "*.bluebook")).each { |path| File.delete(path) }
        end

        # Rewrites every `persisted_by` bind — aggregate-scoped or bare at the hecksagon's
        # own root, naming its adapter as a literal or through a local variable — to name
        # `adapter_name`, and drops every `projected_by` bind outright (unread rather than
        # broken, since `Registry#read_repository` falls back to the authoritative repo).
        def rewrite_bindings!(copy, adapter_name)
          Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |path|
            lines = File.readlines(path).grep_v(/\bprojected_by\s*\(?\s*"/)
            # Horizontal space only: a newline ends the statement, and the next one must stay.
            bind = /persisted_by[ \t]*\(?[ \t]*(?:"[^"]+"|[a-z_]\w*)[ \t]*\)?/
            File.write(path, lines.join.gsub(bind, "persisted_by(\"#{adapter_name}\")"))
          end
        end
      end
    end
  end
end
