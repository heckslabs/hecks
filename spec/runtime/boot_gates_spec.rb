require "spec_helper"
require "tmpdir"

# ADR 0031 — the boot-gate registry itself, plus the assertion this ADR's
# own Consequences promised: a domain bound to a lineage-capable adapter
# always ends up with `:era_check` registered, a domain bound to an
# adapter supporting sagas always ends up with `:saga_rehydration`
# registered, and neither is present at all for a domain with neither
# capability — mirroring `spec/projector_seam_spec.rb`'s registration-
# completeness enforcement, scaled to two hand-registered gates.
RSpec.describe Hecks::Runtime::BootGates do
  describe "the registry itself" do
    it "runs a registered gate, handing it the registry and directory" do
      gates = described_class.new
      seen = nil
      gates.register(:probe, ->(registry, directory) { seen = [registry, directory] }, phase: :pre_verify)

      gates.run!(:pre_verify, :a_registry, "/some/dir")

      expect(seen).to eq([:a_registry, "/some/dir"])
    end

    it "never runs a gate registered under a different phase" do
      gates = described_class.new
      ran = false
      gates.register(:probe, ->(*) { ran = true }, phase: :post_verify)

      gates.run!(:pre_verify, :a_registry, "/some/dir")

      expect(ran).to be false
    end

    it "answers registered? for a gate that was registered, regardless of phase" do
      gates = described_class.new
      gates.register(:probe, ->(*) {}, phase: :post_verify)

      expect(gates.registered?(:probe)).to be true
      expect(gates.registered?(:nothing_registered_this)).to be false
    end

    it "is instance-scoped — a fresh instance starts with nothing registered" do
      first = described_class.new
      first.register(:probe, ->(*) {}, phase: :pre_verify)

      expect(described_class.new.registered?(:probe)).to be false
    end
  end

  describe "Loader's own wiring, end to end" do
    around do |example|
      @dir = Dir.mktmpdir("hecks-boot-gates-")
      example.run
    ensure
      FileUtils.remove_entry(@dir) if @dir
    end

    def boot_registry(&block)
      registry = Hecks::Runtime::Registry.new(root: @dir)
      Hecks.with_registry(registry, &block)
      registry
    end

    it "registers neither gate for a domain with nothing lineage- or saga-capable bound" do
      registry = boot_registry do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Plain") do
          aggregate("Thing") do
            identified_by :name
            attribute :name, Name
            value_object("Name") { attribute :value, String }
          end
        end
        Hecks.hecksagon("Plain") { persisted_by "Memory" }
      end

      gates = Hecks::Runtime::Loader.run_boot_gates!(registry, @dir)

      expect(gates.registered?(:era_check)).to be false
      expect(gates.registered?(:saga_rehydration)).to be false
    end

    it "registers :saga_rehydration, but not :era_check, for a domain bound to an adapter that supports sagas but carries no eras" do
      sqlite_adapter = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")
      dir = @dir
      registry = boot_registry do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(sqlite_adapter)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Saved") do
          aggregate("Thing") do
            identified_by :name
            attribute :name, Name
            value_object("Name") { attribute :value, String }
          end
        end
        Hecks.hecksagon("Saved") { persisted_by "SqlitePersistence" }
        Hecks.world("Saved") { persisted_by("SqlitePersistence") { database(File.join(dir, "saved.db")) } }
      end

      gates = Hecks::Runtime::Loader.run_boot_gates!(registry, @dir)

      expect(gates.registered?(:saga_rehydration)).to be true
      expect(gates.registered?(:era_check)).to be false
    end

    it "registers :era_check for a domain with an aggregate bound to a lineage-capable adapter (PostgresEra), needing no live database" do
      # `lineage_capable?`'s own `require "pg"` stays lazy — see
      # spec/exporter_spec.rb's identical registry-construction comment —
      # so asking the REGISTRATION question never needs a live Postgres.
      require InMemoryDomain::ERA_PLUGIN
      registry = boot_registry do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
        Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.hecksagon"))
      end

      expect(Hecks::Runtime::EraCheck.lineage_capable_registry?(registry)).to be true
    end
  end
end
