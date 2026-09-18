require "spec_helper"

# ROADMAP I3, SECOND HALF — `dispatch` took command facts as loose keyword
# arguments until 1.3.x, deprecated there and removed here. One bag holding
# both the receiver's identity and the command's payload is the shape behind
# nine past routing bugs; the receiver goes in `to:`, the facts in `with:`,
# and a caller holding a bag of DATA rather than written keywords calls
# `dispatch_flat`, which is the wire form and stays.
#
# Ruby itself is the refusal now — an unknown keyword, named — so this file
# pins the shape of that refusal rather than a message of ours, and pins that
# the two doors that remain still work.
RSpec.describe "dispatch takes no loose keyword facts" do
  PIZZA_FACTS = { name:  { value: "Margherita" },
                  pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }.freeze

  let(:runtime) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      Hecks.hecksagon("Pizzas") do
        uses_framework "Governance"
        Pizzas::Order.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecks::Runtime::Dispatcher.new(registry)
  end

  it "refuses a loose fact by name, as an ArgumentError" do
    expect { runtime.dispatch("Pizzas::Order.CreatePizza", **PIZZA_FACTS) }
      .to raise_error(ArgumentError, /unknown keywords?: :name, :pizza/)
  end

  it "still takes the facts in with:, and the receiver in to:" do
    expect(runtime.dispatch("Pizzas::Order.CreatePizza", with: PIZZA_FACTS).id).to eq("Margherita")
    expect(runtime.dispatch("Pizzas::Order.AddTopping", to:   "Margherita",
                                                        with: { topping: { value: "Basil" },
                                                                amount:  { value: 3 } }).id).to eq("Margherita")
  end

  # The wire form: one Hash, the receiver's identity among the keys, exactly
  # as `spec/corpus/*.json` and `cli.rs` spell it.
  it "still takes a flat facts hash through dispatch_flat" do
    expect(runtime.dispatch_flat("Pizzas::Order.CreatePizza", PIZZA_FACTS).id).to eq("Margherita")
  end

  it "leaves no loose-keyword door on the dispatcher at all" do
    %i[dispatch dispatch_port].each do |door|
      kinds = Hecks::Runtime::Dispatcher.instance_method(door).parameters.map(&:first)
      expect(kinds).not_to include(:keyrest), "##{door} still accepts loose keywords"
    end
  end
end
