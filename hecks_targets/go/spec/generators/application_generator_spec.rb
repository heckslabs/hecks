require "spec_helper"
require "go_hecks"

RSpec.describe GoHecks::ApplicationGenerator do
  let(:domain) do
    Hecks.domain("Pizzas") do
      aggregate("Pizza") do
        attribute :name, String
        command("CreatePizza") { attribute :name, String }
        command("UpdatePizza") { attribute :pizza, String; attribute :name, String }
      end

      aggregate("Order") do
        reference_to "Pizza"
        attribute :quantity, Integer
        command("PlaceOrder") { reference_to "Pizza"; attribute :quantity, Integer }
      end
    end
  end

  let(:generator) { described_class.new(domain, module_path: "pizzas_domain") }
  let(:output) { generator.generate }

  describe "package and imports" do
    it "declares runtime package" do
      expect(output).to include("package runtime")
    end

    it "imports domain and memory adapter packages" do
      expect(output).to include('"pizzas_domain/domain"')
      expect(output).to include('"pizzas_domain/adapters/memory"')
    end

    it "imports encoding/json for command decoding" do
      expect(output).to include('"encoding/json"')
    end
  end

  describe "Application struct" do
    it "declares repo fields for each aggregate" do
      expect(output).to include("PizzaRepo domain.PizzaRepository")
      expect(output).to include("OrderRepo domain.OrderRepository")
    end

    it "includes EventBus and CommandBus" do
      expect(output).to include("EventBus   *EventBus")
      expect(output).to include("CommandBus *CommandBus")
    end
  end

  describe "Boot function" do
    it "generates a Boot constructor" do
      expect(output).to include("func Boot() *Application {")
    end

    it "initializes memory repositories" do
      expect(output).to include("PizzaRepo: memory.NewPizzaMemoryRepository()")
      expect(output).to include("OrderRepo: memory.NewOrderMemoryRepository()")
    end

    it "wires EventBus and CommandBus" do
      expect(output).to include("eventBus := NewEventBus()")
      expect(output).to include("CommandBus: NewCommandBus(eventBus)")
    end
  end

  describe "Run method" do
    it "generates a Run method with command name dispatch" do
      expect(output).to include("func (app *Application) Run(commandName string, jsonAttrs []byte)")
    end

    it "routes each command to its Execute method" do
      expect(output).to include('case "CreatePizza":')
      expect(output).to include('case "UpdatePizza":')
      expect(output).to include('case "PlaceOrder":')
    end

    it "unmarshals JSON into the command struct" do
      expect(output).to include("json.Unmarshal(jsonAttrs, &c)")
    end

    it "publishes the event after execution" do
      expect(output).to include("app.EventBus.Publish(event)")
    end

    it "returns a CommandResult with aggregate and event" do
      expect(output).to include("CommandResult{Aggregate: agg, Event: event}")
    end

    it "returns error for unknown commands" do
      expect(output).to include('fmt.Errorf("unknown command: %s", commandName)')
    end
  end

  describe "accessor methods" do
    it "generates Events accessor" do
      expect(output).to include("func (app *Application) Events() []DomainEvent {")
    end

    it "generates On subscription method" do
      expect(output).to include("func (app *Application) On(eventName string, handler func(DomainEvent)) {")
    end

    it "generates Repo accessor with name-based lookup" do
      expect(output).to include("func (app *Application) Repo(name string) interface{} {")
      expect(output).to include('case "Pizza":')
      expect(output).to include('case "Order":')
    end
  end

  describe "CommandResult struct" do
    it "has Aggregate and Event fields" do
      expect(output).to include("Aggregate interface{}")
      expect(output).to include("Event     DomainEvent")
    end
  end
end
