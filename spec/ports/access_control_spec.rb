require "hecksagain"

RSpec.describe Hecksagain::Ports::AccessControl do
  def registry_with(&extra)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecksagain/ports/access_control.port", __dir__))
      extra&.call
    end
    registry
  end

  describe "adapter resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with

      expect { described_class.available_roles(registry) }
        .to raise_error(Hecksagain::Runtime::WiringError, /no adapter implements/)
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with do
        Hecks.adapter("FirstAccessControl") { port "access_control" }
        Hecks.adapter("SecondAccessControl") { port "access_control" }
      end

      expect { described_class.available_roles(registry) }
        .to raise_error(Hecksagain::Runtime::WiringError, /FirstAccessControl, SecondAccessControl/)
    end
  end
end
