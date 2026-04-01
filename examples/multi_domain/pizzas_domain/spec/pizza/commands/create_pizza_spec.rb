require_relative "../../spec_helper"

RSpec.describe PizzasDomain::Pizza::Commands::CreatePizza do
  describe "attributes" do
    subject(:command) { described_class.new(
          name: "example",
          style: "example",
          price: 1.0
        ) }

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has style" do
      expect(command.style).to eq("example")
    end

    it "has price" do
      expect(command.price).to eq(1.0)
    end

  end

  describe "event" do
    it "emits CreatedPizza" do
      expect(described_class.event_name).to eq("CreatedPizza")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Pizza.create(
          name: "example",
          style: "example",
          price: 1.0
        )
      expect(result).not_to be_nil
      expect(Pizza.find(result.id)).not_to be_nil
    end

    it "emits CreatedPizza to the event log" do
      Pizza.create(
          name: "example",
          style: "example",
          price: 1.0
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("CreatedPizza")
    end
  end
end
