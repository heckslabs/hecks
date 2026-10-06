require "hecks"

# Mechanically identical to Memory (spec/adapters/driven/memory_spec.rb)
# on purpose — see local_storage.rb's own header for why a Ruby-side
# stand-in for a browser's `window.localStorage` can only ever be that,
# and why the name still earns its own adapter rather than being an
# alias for Memory.
RSpec.describe Hecks::Adapters::LocalStorage do
  def boot_pizzas_on_local_storage
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_pizza_ports
      declare_pizza_hecksagons
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def load_pizza_ports
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
     InMemoryDomain::LOCAL_STORAGE_ADAPTER, InMemoryDomain::PRISM_ADAPTER, InMemoryDomain::PIZZAS_BLUEBOOK]
      .each { |file| Kernel.load(file) }
  end

  def declare_pizza_hecksagons
    Hecks.hecksagon("Pizzas") do
      attaches "Governance"
      Pizzas::Order.persisted_by("LocalStorage")
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  let(:runtime) { boot_pizzas_on_local_storage }

  def repository
    runtime.registry.repository("Pizzas", runtime.registry.bluebook("Pizzas").aggregate("Order"))
  end

  def create(name: "Margherita")
    runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                          name: { value: name }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
  end

  it "boots and dispatches a real domain against it, same as any other persistence adapter", :aggregate_failures do
    order = create(name: "Margherita")

    expect(order.instance.status).to eq("available")
    expect(repository.find(order.instance.id)).not_to be_nil
    expect(repository.count).to eq(1)
  end

  it "answers a declared query correctly through the InMemory fallback" do
    create(name: "Margherita")
    create(name: "Diavola")

    available = runtime.query("Pizzas::Order.Available")
    expect(available.map { |row| row[:name].value }.sort).to eq(%w[Diavola Margherita])
  end

  context "with two pizzas saved" do
    before do
      create(name: "Margherita")
      create(name: "Diavola")
    end

    it "holds the records and the append log until reset", :aggregate_failures do
      expect(repository.count).to eq(2)
      expect(repository.entries).not_to be_empty
    end

    it "clears the saved records on reset" do
      repository.reset!

      expect([repository.count, repository.all]).to eq([0, []])
    end

    it "clears the append log and the recorded events on reset" do
      repository.reset!

      expect([repository.entries, repository.events]).to eq([[], []])
    end
  end

  it "leaves the adapter fully usable afterward — not just empty, but able to save and find again", :aggregate_failures do
    create(name: "Margherita")
    repository.reset!
    pizza = create(name: "Diavola")

    expect(repository.count).to eq(1)
    expect(repository.find(pizza.id)).not_to be_nil
  end

  it "responds to reset! on the raw adapter, not only through AppendOnly's wrapper", :aggregate_failures do
    local_storage = described_class.new(aggregate: runtime.registry.bluebook("Pizzas").aggregate("Order"))
    local_storage.save(Struct.new(:id, :state).new("1", { name: { value: "Margherita" } }))

    expect(local_storage.reset!).to equal(local_storage)
    expect(local_storage.count).to eq(0)
  end
end
