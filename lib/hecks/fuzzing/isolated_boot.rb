require "fileutils"
require "tmpdir"
require "securerandom"
require_relative "outside_world"
require_relative "../runtime/adapter_lookup"
require_relative "isolated_boot/copying"
require_relative "isolated_boot/worlds"
require_relative "isolated_boot/postgres_scratch"

module Hecks
  module Fuzzing
    # Rewrites a copied domain's persistence bindings before an ephemeral
    # fuzz/replay boot; a directory copy alone does not isolate Postgres state.
    module IsolatedBoot
      # Postgres has no zero-config default (Postgres.connect_for refuses without a
      # `database` setting), so every domain name gets a fresh `.world` written for it.
      # One shared schema, dropped and recreated per boot, not a fresh name per call —
      # safe only because callers run one ephemeral boot at a time.
      FUZZ_POSTGRES_DATABASE = "hecks_fuzz".freeze
      FUZZ_POSTGRES_SCHEMA   = "hecks_fuzz".freeze

      extend Copying
      extend Worlds
      extend PostgresScratch

      module_function

      # Copies `domain_path` to a tmpdir, rebinds its persistence to `adapter`, and
      # yields the copy's root. `:postgres` is expensive: use smaller seed/step counts.
      #
      # The block runs with `OutsideWorld` standing in for every adapter a port or a port-answered
      # query reaches: a fuzz or replay checks the domain's own rules, and the adapters of the
      # chapters that drive tools would run shells and write files from a generated sequence.
      def call(domain_path, adapter: :memory, database: nil, schema: nil, scratch: {})
        Dir.mktmpdir("hecks-fuzz") do |tmp|
          copy = File.join(tmp, File.basename(domain_path))
          copy_dereferencing(domain_path, copy)
          FileUtils.rm_rf(File.join(copy, "data"))
          rebind!(copy, adapter, database: database, schema: schema, scratch: scratch)
          Runtime::AdapterLookup.standing_in(OutsideWorld) { yield copy }
        end
      end

      # Rewrites the copy's bindings for `adapter`.
      #
      # @raise [ArgumentError] if `adapter` is not one of the fuzz adapters
      def rebind!(copy, adapter, database:, schema:, scratch:)
        case adapter
        when :memory       then rebind_to_memory!(copy)
        when :sqlite       then rebind_to_sqlite!(copy)
        when :postgres     then rebind_to_postgres!(copy, **scratch)
        when :postgres_era then rebind_to_postgres_era!(copy, database: database, schema: schema)
        else raise ArgumentError,
                   "unknown fuzz adapter #{adapter.inspect} — :memory, :sqlite, :postgres, or :postgres_era"
        end
      end

      # Rewrites every `.hecksagon` in the copy to bind through Memory and replaces its
      # `.world` files with a `default_adapter "Memory"` one, so the boot needs no settings.
      def rebind_to_memory!(copy)
        rewrite_bindings!(copy, "Memory")
        strip_translations!(copy)

        # Also replaces the settings, not just the bind: a bare fallback setting (like
        # Postgres's `database:`) would otherwise still apply and WiringError refuses it.
        write_default_worlds!(copy, "Memory")
      end

      # Same as `rebind_to_memory!`, one adapter over — Sqlite also needs no `.world`
      # settings, since `Sqlite#resolve_path` defaults `database` to `data/<table>.db`.
      def rebind_to_sqlite!(copy)
        rewrite_bindings!(copy, "SqlitePersistence")
        strip_translations!(copy)
        write_default_worlds!(copy, "SqlitePersistence")
      end
    end
  end
end
