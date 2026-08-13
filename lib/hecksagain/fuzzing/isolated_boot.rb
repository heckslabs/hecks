require "fileutils"
require "tmpdir"

module Hecksagain
  module Fuzzing
    # A FRESH, IN-PROCESS ADAPTER FOR EVERY EPHEMERAL BOOT.
    #
    # Fuzzing/replay copies a domain to a tmpdir and boots from there
    # specifically to get zero-history state — `rm_rf`ing the copy's own
    # `data/` achieves that for a file-based adapter (Memory,
    # SqlitePersistence, Heki), because copying the DIRECTORY copies the
    # store. It achieves nothing for an adapter that lives outside the
    # copied directory entirely — Postgres, named by a fixed connection
    # string in `.world` (examples/pizzas/bluebook/pizzas.world, for
    # instance). Copying the directory does not copy or isolate the
    # DATABASE, so a "fresh" boot against a Postgres-bound domain would
    # still see every record any other run, ever, wrote to it.
    #
    # So every `.hecksagon` in the copy gets its persistence binding
    # rewritten to Memory before booting, and any `projected_by` bind
    # dropped outright (optional — `Registry#read_repository` already
    # falls back to the authoritative repository when none exists). The
    # domain's own rules and shape are untouched ; only WHICH adapter this
    # one ephemeral copy answers through changes. What the domain is
    # bound to for real deployment is never touched — only this tmp copy.
    module IsolatedBoot
      module_function

      def call(domain_path)
        Dir.mktmpdir("hecksagain-fuzz") do |tmp|
          copy = File.join(tmp, File.basename(domain_path))
          FileUtils.cp_r(domain_path, copy)
          FileUtils.rm_rf(File.join(copy, "data"))
          rebind_to_memory!(copy)
          yield copy
        end
      end

      def rebind_to_memory!(copy)
        Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |path|
          # `persisted_by`/`projected_by` can be spelled two ways now —
          # aggregate-scoped (`Banking::Customer.persisted_by("Heki")`,
          # always parenthesised) and, since §0's domain-level default
          # binds, a bare call at the hecksagon's own root
          # (`persisted_by "Heki"`, no parens, no receiver). Both must
          # be caught here or a domain that only declares the bare form
          # keeps its real adapter under an "isolated" fuzz boot.
          lines = File.readlines(path).reject { |line| line.match?(/\bprojected_by\s*\(?\s*"/) }
          File.write(path, lines.join.gsub(/persisted_by\s*\(?\s*"[^"]+"\s*\)?/, 'persisted_by("Memory")'))
        end

        # THE SETTINGS, NOT JUST THE BIND — `WorldBuilder#method_missing`
        # stores a settings block under BOTH "verb:adapter" and the bare
        # "verb" (world_builder.rb:32-33), so a bind rewritten to Memory
        # still falls back to whatever adapter's settings were declared
        # bare — Postgres's `database:`, which Memory does not take and
        # WiringError refuses on sight. Memory needs no settings at all
        # (a domain with no .world boots it as the default), so the
        # simplest correct fix is dropping .world from the copy entirely.
        Dir.glob(File.join(copy, "**", "*.world")).each { |path| File.delete(path) }
      end
    end
  end
end
