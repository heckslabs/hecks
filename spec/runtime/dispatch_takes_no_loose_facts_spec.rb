require "spec_helper"

# `dispatch` takes the receiver in `to:` and the facts in `with:`; a bag of data goes
# through `dispatch_flat`. Ruby's own unknown-keyword ArgumentError is the refusal.
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
        attaches "Governance"
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

  it "still takes the facts in with:, and the receiver in to:", :aggregate_failures do
    expect(runtime.dispatch("Pizzas::Order.CreatePizza", with: PIZZA_FACTS).id).to eq("Margherita")
    expect(runtime.dispatch("Pizzas::Order.AddTopping", to:   "Margherita",
                                                        with: { topping: { value: "Basil" },
                                                                amount:  { value: 3 } }).id).to eq("Margherita")
  end

  # The wire form: one Hash with the receiver's identity among the keys.
  it "still takes a flat facts hash through dispatch_flat" do
    expect(runtime.dispatch_flat("Pizzas::Order.CreatePizza", PIZZA_FACTS).id).to eq("Margherita")
  end

  it "leaves no loose-keyword entry on the dispatcher at all" do
    %i[dispatch dispatch_port].each do |verb|
      kinds = Hecks::Runtime::Dispatcher.instance_method(verb).parameters.map(&:first)
      expect(kinds).not_to include(:keyrest), "##{verb} still accepts loose keywords"
    end
  end
end
