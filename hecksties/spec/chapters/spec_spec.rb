require "spec_helper"
require "hecks/chapters/spec"

RSpec.describe Hecks::Chapters::Spec do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Spec" do
    expect(domain.name).to eq("Spec")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include(
      "TestHelper", "InMemoryLoader", "MemoryAdapter",
      "MemoryOutbox", "EventBus", "InMemoryExecutor",
      "SpecGenerator", "SpecHelpers", "SpecWriter", "ServerHelpers",
      "Pizza", "Order"
    )
  end

  it "has commands on TestHelper" do
    agg = domain.aggregates.find { |a| a.name == "TestHelper" }
    expect(agg.commands.map(&:name)).to include("Reset")
  end

  it "has commands on EventBus" do
    agg = domain.aggregates.find { |a| a.name == "EventBus" }
    expect(agg.commands.map(&:name)).to include("Subscribe", "Publish", "Clear")
  end

  it "has commands on SpecGenerator" do
    agg = domain.aggregates.find { |a| a.name == "SpecGenerator" }
    expect(agg.commands.map(&:name)).to include("GenerateSpecHelper")
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  describe "Pizza aggregate" do
    let(:pizza) { domain.aggregates.find { |a| a.name == "Pizza" } }

    it "has value objects, validations, queries, and commands" do
      expect(pizza.commands.map(&:name)).to include("CreatePizza", "AddTopping")
      expect(pizza.value_objects.map(&:name)).to include("Topping")
      expect(pizza.queries.map(&:name)).to include("ByDescription")
    end
  end

  describe "Order aggregate" do
    let(:order) { domain.aggregates.find { |a| a.name == "Order" } }

    it "has references, transitions, value objects, and commands" do
      expect(order.commands.map(&:name)).to include("PlaceOrder", "CancelOrder")
      expect(order.value_objects.map(&:name)).to include("OrderItem")
      expect(order.queries.map(&:name)).to include("Pending")
    end
  end
end
