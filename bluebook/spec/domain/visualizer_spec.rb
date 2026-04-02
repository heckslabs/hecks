require "spec_helper"

RSpec.describe Hecks::DomainVisualizer do
  let(:domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String
        attribute :style, String
        attribute :toppings, list_of("Topping")

        value_object "Topping" do
          attribute :name, String
          attribute :amount, Integer
        end

        command "CreatePizza" do
          attribute :name, String
          attribute :style, String
        end

        policy "NotifyKitchen" do
          on "CreatedPizza"
          trigger "CreatePizza"
        end
      end

      aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer

        command "PlaceOrder" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end

        policy "SendConfirmation" do
          on "PlacedOrder"
          trigger "PlaceOrder"
          async true
        end
      end
    end
  end

  subject(:visualizer) { described_class.new(domain) }
  let(:mermaid) { visualizer.generate }

  describe "structure diagram" do
    it "contains a classDiagram block" do
      expect(mermaid).to include("classDiagram")
    end

    it "includes aggregate names as classes" do
      expect(mermaid).to include("class Pizza {")
      expect(mermaid).to include("class Order {")
    end

    it "includes attribute type annotations" do
      expect(mermaid).to include("+String name")
      expect(mermaid).to include("+Integer quantity")
    end

    it "shows list attributes with array notation" do
      expect(mermaid).to include("+Topping[] toppings")
    end

    it "shows value object composition" do
      expect(mermaid).to include("Pizza *-- Topping")
    end

    it "shows cross-aggregate references" do
      expect(mermaid).to include("Order --> Pizza : pizza")
    end
  end

  describe "behavior diagram" do
    it "contains a flowchart block" do
      expect(mermaid).to include("flowchart LR")
    end

    it "includes command nodes" do
      expect(mermaid).to include("Pizza_CreatePizza[CreatePizza]")
      expect(mermaid).to include("Order_PlaceOrder[PlaceOrder]")
    end

    it "includes event nodes with stadium shape" do
      expect(mermaid).to include("Pizza_CreatedPizza([CreatedPizza])")
      expect(mermaid).to include("Order_PlacedOrder([PlacedOrder])")
    end

    it "links commands to events" do
      expect(mermaid).to include("Pizza_CreatePizza --> Pizza_CreatedPizza")
    end

    it "shows policy connections with dashed arrows" do
      expect(mermaid).to include("Pizza_CreatedPizza -.->|NotifyKitchen| Pizza_CreatePizza")
    end

    it "labels async policies" do
      expect(mermaid).to include("SendConfirmation [async]")
    end

    it "groups nodes by aggregate subgraph" do
      expect(mermaid).to include("subgraph Pizza")
      expect(mermaid).to include("subgraph Order")
    end
  end

  describe "#print" do
    it "outputs to stdout" do
      expect { visualizer.print }.to output(/classDiagram/).to_stdout
    end
  end

  describe "Hecks.visualize" do
    it "returns a mermaid string" do
      expect(Hecks.visualize(domain)).to include("classDiagram")
    end
  end

  describe "Domain#to_mermaid" do
    it "returns a mermaid string" do
      expect(domain.to_mermaid).to include("classDiagram")
    end
  end

  describe "Domain#visualize" do
    it "prints to stdout" do
      expect { domain.visualize }.to output(/classDiagram/).to_stdout
    end
  end

  describe "aggregate ports diagram" do
    subject(:ports_diagram) { visualizer.generate_aggregate_ports }

    it "contains a flowchart block" do
      expect(ports_diagram).to include("flowchart LR")
    end

    it "groups commands by aggregate subgraph" do
      expect(ports_diagram).to include("subgraph Pizza")
      expect(ports_diagram).to include("subgraph Order")
    end

    it "shows commands as driving-port nodes entering the aggregate" do
      expect(ports_diagram).to include("Pizza_CreatePizza_cmd([CreatePizza])-->Pizza")
      expect(ports_diagram).to include("Order_PlaceOrder_cmd([PlaceOrder])-->Order")
    end

    it "omits persistence node by default" do
      expect(ports_diagram).not_to include("Persistence")
    end

    it "omits event bus node by default" do
      expect(ports_diagram).not_to include("EventBus")
    end

    context "with show_persistence: true" do
      subject(:ports_diagram) { visualizer.generate_aggregate_ports(show_persistence: true) }

      it "includes a Persistence driven-port node for each aggregate" do
        expect(ports_diagram).to include("Pizza-->Pizza_Persistence[(Persistence)]")
        expect(ports_diagram).to include("Order-->Order_Persistence[(Persistence)]")
      end
    end

    context "with show_event_bus: true" do
      subject(:ports_diagram) { visualizer.generate_aggregate_ports(show_event_bus: true) }

      it "includes an EventBus driven-port node for each aggregate" do
        expect(ports_diagram).to include("Pizza-->Pizza_EventBus{{EventBus}}")
        expect(ports_diagram).to include("Order-->Order_EventBus{{EventBus}}")
      end
    end

    context "generate includes the aggregate ports block" do
      it "the main generate output contains the ports flowchart" do
        expect(mermaid).to include("Pizza_CreatePizza_cmd([CreatePizza])-->Pizza")
      end
    end
  end
end
