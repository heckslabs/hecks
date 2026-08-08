require "hecksagain"

RSpec.describe Hecksagain::Ports::Authorization do
  def registry_with(*adapter_paths, &extra)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecksagain/ports/authorization.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
      extra&.call
    end
    registry
  end

  def governance_adapter
    File.expand_path("../../lib/hecksagain/adapters/driven/governance_authorization.adapter", __dir__)
  end

  describe "resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with
      expect { described_class.holds_role?(registry, actor_id: "u-1", role: "Teller") }
        .to raise_error(Hecksagain::Runtime::WiringError, /no adapter implements/)
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with(governance_adapter) { Hecks.adapter("AlwaysAllow") { port "authorization" } }

      expect { described_class.holds_role?(registry, actor_id: "u-1", role: "Teller") }
        .to raise_error(Hecksagain::Runtime::WiringError, /AlwaysAllow, GovernanceAuthorization/)
    end
  end
end
