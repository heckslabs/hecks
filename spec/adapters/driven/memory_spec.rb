require "hecks"

# `Memory#reset!` returns the adapter to the clean slate a fresh `Hecks.boot` gives, so a caller
# can reuse one booted runtime across cases.
RSpec.describe Hecks::Adapters::Memory do
  let(:runtime) { boot_in_memory }

  def repository
    runtime.registry.repository("Pizzas", runtime.registry.bluebook("Pizzas").aggregate("Order"))
  end

  def create(name: "Margherita")
    runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                          name: { value: name }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
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

  # `registry.repository` returns an `AppendOnly` wrapper, so the examples above go through its
  # forwarding; this one checks the raw adapter.
  it "responds to reset! on the raw adapter, not only through AppendOnly's wrapper", :aggregate_failures do
    memory = described_class.new(aggregate: runtime.registry.bluebook("Pizzas").aggregate("Order"))
    memory.save(Struct.new(:id, :state).new("1", { name: { value: "Margherita" } }))

    expect(memory.reset!).to equal(memory)
    expect(memory.count).to eq(0)
  end
end
