require "hecks"

RSpec.describe Hecks::Ports::KeyVault do
  def registry_with(*adapter_paths)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecks/ports/key_vault.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
    end
    registry
  end

  IN_PROCESS_ADAPTER = File.expand_path("../../lib/hecks/adapters/driven/in_process_key_vault.adapter", __dir__)

  before { Hecks::Adapters::InProcessKeyVault.reset! }

  describe "resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with
      expect { described_class.issue(registry, subject_id: "attendee-482") }
        .to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
    end

    it "resolves the one bound adapter, minting and then destroying its key" do
      registry      = registry_with(IN_PROCESS_ADAPTER)
      key_reference = described_class.issue(registry, subject_id: "attendee-482")

      expect(Hecks::Adapters::InProcessKeyVault.fetch(key_reference)).to be_a(String)
      expect(described_class.destroy(registry, key_reference: key_reference)).to be(true)
      expect(Hecks::Adapters::InProcessKeyVault.fetch(key_reference)).to be_nil
    end
  end
end
