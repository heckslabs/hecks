require "spec_helper"

RSpec.describe "Runtime#dry_run" do
  let(:domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String
        attribute :style, String

        command "CreatePizza" do
          attribute :name, String
          attribute :style, String
        end
      end

      aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer

        command "PlaceOrder" do
          reference_to "Pizza", validate: false
          attribute :quantity, Integer
        end

        command "NotifyChef" do
          reference_to "Pizza", validate: false
        end

        policy "NotifyKitchen" do
          on "PlacedOrder"
          trigger "NotifyChef"
        end
      end
    end
  end

  subject(:app) { Hecks.load(domain) }

  after { Hecks::Utils.cleanup_constants! }

  describe "basic dry run" do
    it "returns a DryRunResult" do
      result = app.dry_run("CreatePizza", name: "Margherita", style: "Classic")
      expect(result).to be_a(Hecks::DryRunResult)
    end

    it "reports valid" do
      result = app.dry_run("CreatePizza", name: "Margherita", style: "Classic")
      expect(result.valid?).to be true
    end

    it "populates aggregate" do
      result = app.dry_run("CreatePizza", name: "Margherita", style: "Classic")
      expect(result.aggregate.name).to eq("Margherita")
      expect(result.aggregate.style).to eq("Classic")
    end

    it "populates event" do
      result = app.dry_run("CreatePizza", name: "Margherita", style: "Classic")
      expect(result.event).to be_a(PizzasDomain::Pizza::Events::CreatedPizza)
      expect(result.event.name).to eq("Margherita")
    end
  end

  describe "no side effects" do
    it "does not persist the aggregate" do
      app.dry_run("CreatePizza", name: "Margherita", style: "Classic")
      expect(app["Pizza"].all).to be_empty
    end

    it "does not publish events" do
      app.dry_run("CreatePizza", name: "Margherita", style: "Classic")
      expect(app.events).to be_empty
    end
  end

  describe "reactive chain" do
    it "traces downstream policies for PlaceOrder" do
      result = app.dry_run("PlaceOrder", pizza: "fake-id", quantity: 3)
      expect(result.triggers_policies?).to be true
      policy_names = result.reactive_chain.select { |s| s[:type] == :policy }.map { |s| s[:policy] }
      expect(policy_names).to include("NotifyKitchen")
    end

    it "returns empty chain when no policies react" do
      result = app.dry_run("CreatePizza", name: "Margherita", style: "Classic")
      expect(result.triggers_policies?).to be false
    end
  end
end
