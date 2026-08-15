require "hecksagain"
require_relative "../fixtures/sequential_identity"

RSpec.describe Hecksagain::Ports::IdentityGeneration do
  def registry_with(*adapter_paths)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../../lib/hecksagain/ports/identity_generation.port", __dir__))
      adapter_paths.each { |path| Kernel.load(path) }
    end
    registry
  end

  SECURE_RANDOM_ADAPTER = File.expand_path("../../lib/hecksagain/adapters/driven/secure_random_identity.adapter", __dir__)
  SEQUENTIAL_ADAPTER    = File.expand_path("../fixtures/sequential_identity.adapter", __dir__)

  describe "resolution" do
    it "refuses when no adapter implements the port" do
      registry = registry_with
      expect { described_class.uuid(registry) }
        .to raise_error(Hecksagain::Runtime::WiringError, /no adapter implements/)
    end

    it "resolves the one bound adapter" do
      registry = registry_with(SEQUENTIAL_ADAPTER)
      Hecksagain::Adapters::SequentialIdentity.reset!

      expect(described_class.uuid(registry)).to eq("1")
    end

    it "refuses to choose between more than one bound adapter" do
      registry = registry_with(SECURE_RANDOM_ADAPTER, SEQUENTIAL_ADAPTER)
      expect { described_class.uuid(registry) }
        .to raise_error(Hecksagain::Runtime::WiringError, /SecureRandomIdentity, SequentialIdentity/)
    end
  end

  describe "against a real creating command" do
    def boot_pizzas
      registry = registry_with(SEQUENTIAL_ADAPTER)
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        Hecks.hecksagon("Pizzas") do
          uses_framework "Governance"
          ::Pizzas::Order.persisted_by("Memory")
        end
        Hecks.hecksagon("Governance") do
          ::Governance::RoleAssignment.persisted_by("Memory")
          ::Governance::RoleTransition.persisted_by("Memory")
        end
      end
      registry.verify!
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end

    let(:pizza_args) { { pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } } }

    it "mints an identity a creating command can use directly — an ordinary string, nothing special" do
      Hecksagain::Adapters::SequentialIdentity.reset!
      runtime = boot_pizzas

      minted = described_class.uuid(runtime.registry)
      result = runtime.dispatch("Pizzas::Order.CreatePizza", name: { value: minted }, **pizza_args)

      expect(result.instance.id).to eq(minted)
    end

    it "replay never re-invokes the adapter — the recorded id round-trips instead of being re-minted" do
      Hecksagain::Adapters::SequentialIdentity.reset!

      # FIRST, LIVE DISPATCH — the adapter is called once, and the minted
      # value becomes an ordinary argument from here on.
      first_runtime = boot_pizzas
      minted        = described_class.uuid(first_runtime.registry)
      first_runtime.dispatch("Pizzas::Order.CreatePizza", name: { value: minted }, **pizza_args)

      # The NEXT real mint should be "2" — proving nothing else touched the
      # adapter during that one dispatch.
      expect(Hecksagain::Adapters::SequentialIdentity.uuid).to eq("2")
      Hecksagain::Adapters::SequentialIdentity.reset!

      # REPLAY — a completely fresh boot, the SAME recorded args (exactly
      # what a corpus script or a captured fuzz-replay step holds; this
      # spec never calls the adapter again to get them).
      replay_runtime = boot_pizzas
      replayed       = replay_runtime.dispatch("Pizzas::Order.CreatePizza", name: { value: minted }, **pizza_args)

      expect(replayed.instance.id).to eq(minted)
      # The adapter's own counter is untouched by replay — the next real
      # mint is still "1", the same value a reset-and-first-call gives.
      expect(Hecksagain::Adapters::SequentialIdentity.uuid).to eq("1")
    end
  end
end
