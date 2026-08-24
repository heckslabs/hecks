require "hecks"

# `Memory` was the one driven adapter without `reset!` — Postgres/
# PostgresEra/Sqlite/D1 all already have it, and `Ports::Persistence::
# AppendOnly#reset!` already forwards to whichever adapter it wraps,
# raising only when the adapter doesn't respond to `reset!` at all. This
# closes that one gap: a caller that keeps ONE booted runtime across many
# cases (skipping `load_domain`'s own per-boot cost) can now reset it back
# to the same clean slate a fresh `Hecks.boot` would have given it.
RSpec.describe Hecks::Adapters::Memory do
  let(:runtime) { boot_in_memory }

  def repository
    runtime.registry.repository("Pizzas", runtime.registry.bluebook("Pizzas").aggregate("Order"))
  end

  def create(name: "Margherita")
    runtime.dispatch("Pizzas::Order.CreatePizza",
                     name: { value: name }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
  end

  it "clears saved records, the append log, and recorded events back to empty" do
    create(name: "Margherita")
    create(name: "Diavola")

    expect(repository.count).to eq(2)
    expect(repository.entries).not_to be_empty

    repository.reset!

    expect(repository.count).to eq(0)
    expect(repository.all).to eq([])
    expect(repository.entries).to eq([])
    expect(repository.events).to eq([])
  end

  it "leaves the adapter fully usable afterward — not just empty, but able to save and find again" do
    create(name: "Margherita")
    repository.reset!
    pizza = create(name: "Diavola")

    expect(repository.count).to eq(1)
    expect(repository.find(pizza.id)).not_to be_nil
  end

  # `registry.repository` always hands back an `AppendOnly`-wrapped
  # adapter (`RepositoryFactory.build`) — every assertion above already
  # went through `AppendOnly#reset!`'s own forwarding, not `Memory#reset!`
  # called bare. This confirms the ONE thing those don't: the raw adapter
  # itself, unwrapped, without which `AppendOnly#reset!` would still raise
  # "append-only adapter cannot reset" today.
  it "responds to reset! on the raw adapter, not only through AppendOnly's wrapper" do
    memory = described_class.new(aggregate: runtime.registry.bluebook("Pizzas").aggregate("Order"))
    memory.save(Struct.new(:id, :state).new("1", { name: { value: "Margherita" } }))

    expect(memory.reset!).to equal(memory)
    expect(memory.count).to eq(0)
  end
end
