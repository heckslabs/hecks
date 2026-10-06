require "hecks"

RSpec.describe Hecks::Ports::Authorization do
  def load_in_memory_ports
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
     InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |path| Kernel.load(path) }
  end

  def registry_with(*adapter_paths, &extra)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      load_in_memory_ports
      Kernel.load(File.expand_path("../../lib/hecks/ports/authorization.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
      extra&.call
    end
    registry
  end

  def governance_adapter
    File.expand_path("../../lib/hecks/adapters/driven/governance_authorization.adapter", __dir__)
  end

  describe "resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with
      expect { described_class.holds_role?(registry, actor_id: "u-1", role: "Teller") }
        .to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with(governance_adapter) { Hecks.adapter("AlwaysAllow") { port "authorization" } }

      expect { described_class.holds_role?(registry, actor_id: "u-1", role: "Teller") }
        .to raise_error(Hecks::Runtime::WiringError, /AlwaysAllow, GovernanceAuthorization/)
    end
  end
end
