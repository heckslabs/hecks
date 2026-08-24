require "hecks"

RSpec.describe Hecks::Ports::IdentityResolution do
  def registry_with(*adapter_paths, &extra)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecks/ports/identity_resolution.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
      extra&.call
    end
    registry
  end

  def identity_registry_adapter
    File.expand_path("../../lib/hecks/adapters/driven/identity_registry.adapter", __dir__)
  end

  describe "resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with
      expect { described_class.resolve(registry, issuer: "google", subject: "sub-1") }
        .to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with(identity_registry_adapter) { Hecks.adapter("AlwaysResolve") { port "identity_resolution" } }

      expect { described_class.resolve(registry, issuer: "google", subject: "sub-1") }
        .to raise_error(Hecks::Runtime::WiringError, /AlwaysResolve, IdentityRegistry/)
    end
  end
end
