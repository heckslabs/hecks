require "hecksagain"
require_relative "../fixtures/sequential_identity"

RSpec.describe Hecksagain::Runtime::CapabilityGraph do
  def identity_generation_port
    File.expand_path("../../lib/hecksagain/ports/identity_generation.port", __dir__)
  end

  def sequential_adapter
    File.expand_path("../fixtures/sequential_identity.adapter", __dir__)
  end

  def secure_random_adapter
    File.expand_path("../../lib/hecksagain/adapters/driven/secure_random_identity.adapter", __dir__)
  end

  # THREE PORTS, TWO BOUND. Persistence and extraction each get their usual
  # adapter (Memory, Prism) ; identity_generation is declared, on purpose,
  # with nothing implementing it — the gap the graph exists to name.
  def registry
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(identity_generation_port)
    end
    registry
  end

  describe "#fulfillments" do
    it "names every declared port, adapters bound and unbound alike" do
      graph = registry.capability_graph

      expect(graph.fulfillments).to eq(
        "persistence"         => ["Memory"],
        "extraction"          => ["Prism"],
        "identity_generation" => []
      )
    end

    it "lists more than one adapter for a port more than one implements" do
      held = registry
      Hecksagain.with_registry(held) { Kernel.load(sequential_adapter) }
      Hecksagain.with_registry(held) { Kernel.load(secure_random_adapter) }

      expect(held.capability_graph.fulfillments["identity_generation"])
        .to contain_exactly("SequentialIdentity", "SecureRandomIdentity")
    end
  end

  describe "#unfulfilled" do
    it "names only the ports with zero bound adapters" do
      expect(registry.capability_graph.unfulfilled).to eq(["identity_generation"])
    end

    it "is empty once every declared port has an adapter" do
      held = registry
      Hecksagain.with_registry(held) { Kernel.load(sequential_adapter) }

      expect(held.capability_graph.unfulfilled).to be_empty
    end
  end

  describe "#cycles" do
    it "is always empty — no port can depend on another in this model" do
      expect(registry.capability_graph.cycles).to eq([])
    end
  end

  it "memoizes the graph per registry, the same way #repository does" do
    held = registry

    expect(held.capability_graph).to be(held.capability_graph)
  end
end
