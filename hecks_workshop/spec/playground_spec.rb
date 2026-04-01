require "spec_helper"

RSpec.describe Hecks::Workshop::Playground do
  before(:all) do
    $stdout = File.open(File::NULL, "w")
    @domain = Hecks.domain "PlaygroundTest" do
      aggregate "Pizza" do
        attribute :name, String
        attribute :toppings, list_of("Topping")

        value_object "Topping" do
          attribute :name, String
          attribute :amount, Integer
        end

        validation :name, presence: true

        command "CreatePizza" do
          attribute :name, String
        end

        command "AddTopping" do
          attribute :name, String
        end
      end

      aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer

        command "PlaceOrder" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end

        command "ReserveStock" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end

        policy "ReserveIngredients" do
          on "PlacedOrder"
          trigger "ReserveStock"
        end
      end
    end
    $stdout = STDOUT
  end

  before { allow($stdout).to receive(:puts) }

  describe "#execute" do
    let(:playground) { described_class.new(@domain) }

    it "executes a command and returns the aggregate" do
      result = playground.execute("CreatePizza", name: "Pepperoni")
      expect(result.name).to eq("Pepperoni")
      expect(result.id).to be_a(String)
    end

    it "captures the event" do
      playground.execute("CreatePizza", name: "Pepperoni")
      event = playground.events.last
      expect(event.occurred_at).to be_a(Time)
    end

    it "collects events" do
      playground.execute("CreatePizza", name: "Margherita")
      playground.execute("CreatePizza", name: "Pepperoni")
      expect(playground.events.size).to eq(2)
    end

    it "reports triggered policies" do
      output = []
      allow($stdout).to receive(:puts) { |msg| output << msg }

      pizza = playground.execute("CreatePizza", name: "Seed")
      playground.execute("PlaceOrder", pizza: pizza.id, quantity: 2)

      expect(output).to include("  Policy: ReserveIngredients -> ReserveStock")
    end

    it "raises for unknown command" do
      expect { playground.execute("FlyToMoon") }.to raise_error(/Unknown command/)
    end
  end

  describe "#commands" do
    let(:playground) { described_class.new(@domain) }

    it "lists available commands with their signatures" do
      list = playground.commands
      expect(list).to include(/CreatePizza.*name.*CreatedPizza/)
      expect(list).to include(/PlaceOrder.*quantity.*PlacedOrder/)
    end
  end

  describe "#events_of" do
    let(:playground) { described_class.new(@domain) }

    it "filters events by type" do
      playground.execute("CreatePizza", name: "Margherita")
      playground.execute("AddTopping", name: "Cheese")

      created = playground.events_of("CreatedPizza")
      expect(created.size).to eq(1)
    end
  end

  describe "#reset!" do
    let(:playground) { described_class.new(@domain) }

    it "clears events" do
      playground.execute("CreatePizza", name: "Pepperoni")
      playground.reset!
      expect(playground.events).to be_empty
    end

    it "clears repositories" do
      playground.execute("CreatePizza", name: "Pepperoni")
      playground.reset!
      mod = Object.const_get("PlaygroundTestDomain")
      expect(mod::Pizza.all).to be_empty
    end
  end
end
