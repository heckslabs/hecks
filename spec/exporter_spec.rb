require "spec_helper"
require "hecks/ports/persistence/plugins/era"

RSpec.describe Hecks::Projector::Exporter do
  # Pizzas' hecksagon attaches Governance, which `provides "authorization"`; the bare
  # bluebook attaches nothing.
  def load_core_ports
    MemoryPorts.load!
  end

  def pizzas_registry(with_hecksagon:)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      load_core_ports
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.hecksagon")) if with_hecksagon
    end
    registry
  end

  EXPORTER_AUTHORIZATION = {
    provider:             "Governance",
    grant:                "Governance::RoleAssignment.Assign",
    assignments:          "Governance::RoleAssignment.AssignmentsForActor",
    assignment_aggregate: "Governance::RoleAssignment"
  }.freeze

  EXPORTER_IDENTITY = {
    provider: "Identity",
    register: "Identity::Identity.Register",
    link:     "Identity::ExternalIdentifier.Link",
    resolve:  "Identity::ExternalIdentifier.ResolvedBy"
  }.freeze

  describe ".authorization" do
    it "names the attached chapter that provides authorization, with its declared verbs qualified" do
      expect(described_class.authorization(pizzas_registry(with_hecksagon: true), "Pizzas")).to eq(EXPORTER_AUTHORIZATION)
    end

    it "answers empty for a domain that attaches no authorization provider" do
      expect(described_class.authorization(pizzas_registry(with_hecksagon: false), "Pizzas")).to eq({})
    end
  end

  describe ".membership" do
    it "answers empty for a domain that attaches no membership provider" do
      expect(described_class.membership(pizzas_registry(with_hecksagon: true), "Pizzas")).to eq({})
    end
  end

  describe ".identity" do
    it "answers empty for a domain that attaches no identity provider" do
      expect(described_class.identity(pizzas_registry(with_hecksagon: true), "Pizzas")).to eq({})
    end

    def declare_identity_hexagons
      Hecks.hecksagon("Probe") do
        attaches "Identity"
        attaches "Governance"
      end
      Hecks.hecksagon("Identity") do
        attaches "Governance"
        Identity::Identity.persisted_by("Memory")
        Identity::ExternalIdentifier.persisted_by("Memory")
      end
    end

    def identity_registry
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        load_core_ports
        ["identity", "governance"].each do |name|
          Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/#{name}.bluebook"))
        end
        declare_identity_hexagons
        sibling_governance!
      end
      registry
    end

    it "names the attached chapter that provides identity, with its declared verbs qualified" do
      expect(described_class.identity(identity_registry, "Probe")).to eq(EXPORTER_IDENTITY)
    end
  end

  describe ".lineage" do
    # Needs a real PostgresEra binding, not `boot_in_memory`'s Memory override, and the
    # era plugin loaded (ADR 0033). `require "pg"` stays lazy, so no database is needed.
    def registry_with_directory_bound_to_postgres
      require InMemoryDomain::ERA_PLUGIN
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        load_core_ports
        Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/directory/bluebook/directory.bluebook"))
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/directory/bluebook/directory.hecksagon"))
      end
      registry
    end

    it "names a Postgres-bound aggregate, qualified by name and storage_name" do
      registry = registry_with_directory_bound_to_postgres

      expect(described_class.lineage(registry, "Directory"))
        .to eq(capable_aggregates: [{ name: "Member", storage_name: "member" }])
    end

    it "answers empty for a domain with nothing bound to a lineage-capable adapter" do
      registry = boot_in_memory.registry

      expect(described_class.lineage(registry, "Pizzas")).to eq(capable_aggregates: [])
    end

    it "agrees with Runtime::EraCheck's own capability predicates, not a re-derived rule", :aggregate_failures do
      registry = registry_with_directory_bound_to_postgres
      member = registry.bluebooks.fetch("Directory").aggregate("Member")
      adapter = Hecks::Runtime::EraCheck.adapter_for(registry, "Directory", member)

      expect(adapter).to eq("PostgresEra")
      expect(Hecks::Runtime::EraCheck.lineage_capable?(registry, adapter)).to be true
    end
  end

  describe ".persistence_adapters / the IR's adapters key" do
    def persistence_binding(*names)
      { aggregates: names.map { |name| { name: "A", storage_name: "a", adapter: name } } }
    end

    let(:files) { described_class.adapter_files_under([File.join(InMemoryDomain::ROOT, "lib")]) }

    it "declares each distinct bound adapter once, in name order, as hecks-parse adapter prints it",
       :aggregate_failures do
      declared = described_class.persistence_adapters(persistence_binding("Memory", "Heki", "Memory"), files)

      expect(declared.map { |adapter| adapter["name"] }).to eq(%w[Heki Memory])
      expect(declared.first).to eq("name" => "Heki", "port" => "persistence", "fields" => ["dir"],
                                   "secrets" => [], "defaults" => { "dir" => "data" })
    end

    it "omits a bound adapter nothing declares and answers [] when nothing is bound", :aggregate_failures do
      expect(described_class.persistence_adapters(persistence_binding("NoSuchAdapter"), files)).to eq([])
      expect(described_class.persistence_adapters(persistence_binding, files)).to eq([])
    end

    it "scans no vendored, build or hidden directory" do
      relative = files.map { |path| path.delete_prefix("#{InMemoryDomain::ROOT}/") }
      expect(relative.grep(%r{/(vendor|node_modules|target|tmp|\.[^/]+)/})).to be_empty
    end
  end
end
