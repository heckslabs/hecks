require "hecks"
require_relative "../fixtures/sequential_identity"

RSpec.describe Hecks::Ports::IdentityGeneration do
  def load_in_memory_ports
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
     InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |path| Kernel.load(path) }
  end

  def registry_with(*adapter_paths)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      load_in_memory_ports
      Kernel.load(File.expand_path("../../lib/hecks/ports/identity_generation.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
    end
    registry
  end

  SECURE_RANDOM_ADAPTER = File.expand_path("../../lib/hecks/adapters/driven/secure_random_identity.adapter", __dir__)
  SEQUENTIAL_ADAPTER    = File.expand_path("../fixtures/sequential_identity.adapter", __dir__)

  describe "resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with
      expect { described_class.uuid(registry) }
        .to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
    end

    it "resolves the one bound adapter" do
      registry = registry_with(SEQUENTIAL_ADAPTER)
      Hecks::Adapters::SequentialIdentity.reset!

      expect(described_class.uuid(registry)).to eq("1")
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with(SECURE_RANDOM_ADAPTER, SEQUENTIAL_ADAPTER)
      expect { described_class.uuid(registry) }
        .to raise_error(Hecks::Runtime::WiringError, /SecureRandomIdentity, SequentialIdentity/)
    end
  end

  describe "against a real creating command" do
    def declare_pizzas
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      Hecks.hecksagon("Pizzas") do
        attaches "Governance"
        Pizzas::Order.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    def boot_pizzas
      registry = registry_with(SEQUENTIAL_ADAPTER)
      Hecks.with_registry(registry) { declare_pizzas }
      registry.verify!
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    let(:pizza_args) { { pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } } }

    def create_pizza(runtime, id)
      runtime.dispatch_flat("Pizzas::Order.CreatePizza", name: { value: id }, **pizza_args)
    end

    before { Hecks::Adapters::SequentialIdentity.reset! }

    it "mints an identity a creating command can use directly — an ordinary string, nothing special" do
      runtime = boot_pizzas

      minted = described_class.uuid(runtime.registry)

      expect(create_pizza(runtime, minted).instance.id).to eq(minted)
    end

    describe "replay never re-invokes the adapter — the recorded id round-trips instead of being re-minted" do
      # **First, live dispatch** — the adapter is called once, and the minted
      # value becomes an ordinary argument from here on.
      let(:minted) do
        first_runtime = boot_pizzas
        described_class.uuid(first_runtime.registry).tap { |id| create_pizza(first_runtime, id) }
      end

      # Replay — a completely fresh boot, the same recorded args (exactly
      # what a corpus script or a captured fuzz-replay step holds; these
      # specs never call the adapter again to get them).
      def replay
        recorded = minted
        Hecks::Adapters::SequentialIdentity.reset!
        create_pizza(boot_pizzas, recorded)
      end

      it "touches the adapter once for the live dispatch, so the next real mint is 2" do
        minted

        expect(Hecks::Adapters::SequentialIdentity.uuid).to eq("2")
      end

      it "replays the recorded id" do
        expect(replay.instance.id).to eq(minted)
      end

      it "leaves the adapter's counter untouched by replay, so the next real mint is still 1" do
        replay

        expect(Hecks::Adapters::SequentialIdentity.uuid).to eq("1")
      end
    end
  end
end
