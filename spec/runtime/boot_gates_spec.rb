require "spec_helper"
require "tmpdir"

# Boot-gate registry (ADR 0031): `:era_check` for lineage-capable adapters, `:saga_rehydration`
# for saga-capable ones, and neither for a domain with neither capability.
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

    it "answers registered? for a gate that was registered, regardless of phase", :aggregate_failures do
      gates = described_class.new
      gates.register(:probe, ->(*) {}, phase: :post_verify)

      expect(gates.registered?(:probe)).to be true
      expect(gates.registered?(:nothing_registered_this)).to be false
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

    def load_memory_ports
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    end

    def declare_thing(domain)
      Hecks.bluebook(domain) do
        aggregate("Thing") do
          identified_by :name
          attribute :name, Name
          value_object("Name") { attribute :value, String }
        end
      end
    end

    def plain_registry
      boot_registry do
        load_memory_ports
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        declare_thing("Plain")
        Hecks.hecksagon("Plain") { persisted_by "Memory" }
      end
    end

    def sqlite_registry
      sqlite_adapter = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")
      db_path = File.join(@dir, "saved.db")
      boot_registry do
        load_memory_ports
        Kernel.load(sqlite_adapter)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        declare_thing("Saved")
        Hecks.hecksagon("Saved") { persisted_by "SqlitePersistence" }
        Hecks.world("Saved") { persisted_by("SqlitePersistence") { database(db_path) } }
      end
    end

    def postgres_era_registry
      boot_registry do
        load_memory_ports
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/directory/bluebook/directory.bluebook"))
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/directory/bluebook/directory.hecksagon"))
      end
    end

    it "registers neither gate for a domain with nothing lineage- or saga-capable bound", :aggregate_failures do
      gates = Hecks::Runtime::Loader.run_boot_gates!(plain_registry, @dir)

      expect(gates.registered?(:era_check)).to be false
      expect(gates.registered?(:saga_rehydration)).to be false
    end

    it "registers :saga_rehydration, but not :era_check, for a domain bound to an adapter that supports sagas " \
       "but carries no eras", :aggregate_failures do
      gates = Hecks::Runtime::Loader.run_boot_gates!(sqlite_registry, @dir)

      expect(gates.registered?(:saga_rehydration)).to be true
      expect(gates.registered?(:era_check)).to be false
    end

    it "registers :era_check for a domain with an aggregate bound to a lineage-capable adapter (PostgresEra), " \
       "needing no live database" do
      # `lineage_capable?` keeps `require "pg"` lazy, so no live Postgres is needed here.
      require InMemoryDomain::ERA_PLUGIN

      expect(Hecks::Runtime::EraCheck.lineage_capable_registry?(postgres_era_registry)).to be true
    end
  end
end
