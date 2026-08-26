require "spec_helper"

# THE UNIVERSAL MCP DOOR — dispatch/query/state/catalog/describe/validate,
# projected off the SAME machinery `CliRunner`/`JsonDoor` already use, so
# these specs prove composition rather than re-deriving verb resolution or
# JSON materialization from scratch.
RSpec.describe Hecks::Facade::McpDoor do
  let(:runtime) { boot_in_memory }
  let(:pizza_args) do
    { name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }
  end

  describe ".dispatch" do
    it "issues the command and answers the record's id, state, and events" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza",
                                        summary: "spec", args: pizza_args)

      expect(result[:ok]).to be true
      expect(result[:id]).to eq("Margherita")
      expect(result[:state][:status]).to eq("available")
      expect(result[:events].map { |e| e[:name] }).to eq(["PizzaCreated"])
    end

    it "resolves the qualified form identically to the short form" do
      short      = described_class.dispatch(runtime: runtime, command: "create_pizza",
                                            summary: "spec", args: pizza_args)
      qualified  = described_class.dispatch(runtime: runtime, command: "order.create_pizza", summary: "spec",
                                            args: pizza_args.merge(name: { value: "Diavola" }))

      expect(short[:ok]).to be true
      expect(qualified[:ok]).to be true
    end

    it "refuses a summary-less call rather than dispatching" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "", args: pizza_args)

      expect(result[:ok]).to be false
      expect(result[:error]).to include("summary")
      expect(runtime.events).to be_empty
    end

    it "answers a structured refusal, not a raised error, for an unknown command" do
      result = described_class.dispatch(runtime: runtime, command: "no_such_command", summary: "spec")

      expect(result[:ok]).to be false
      expect(result[:summary]).to eq("spec")
      expect(result[:error]).to include("no such command")
    end

    it "answers a structured refusal for a domain rule violation" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args)
      described_class.dispatch(runtime: runtime, command: "order.add_topping", summary: "spec",
                               args: { to: "Margherita", topping: { value: "Basil" }, amount: { value: 1 } })
      purchase_args = { to: "Margherita", amount: { cents: 1200 }, customer_name: { value: "Alex" } }
      sold           = described_class.dispatch(runtime: runtime, command: "order.purchase", summary: "spec",
                                                args: purchase_args)
      purchase_again = described_class.dispatch(runtime: runtime, command: "order.purchase", summary: "spec",
                                                args: purchase_args)

      expect(sold[:ok]).to be true
      expect(purchase_again[:ok]).to be false
      expect(purchase_again[:error]).to be_a(String)
    end
  end

  describe ".query" do
    it "answers the declared question's rows" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args)

      result = described_class.query(runtime: runtime, question: "available", summary: "spec")

      expect(result[:ok]).to be true
      expect(result[:rows].map { |row| row[:id] }).to eq(["Margherita"])
    end

    it "refuses an unknown question" do
      result = described_class.query(runtime: runtime, question: "no_such_question", summary: "spec")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("no such query")
    end
  end

  describe ".state" do
    before { described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args) }

    it "answers every record when id is omitted" do
      result = described_class.state(runtime: runtime, aggregate: "Order", summary: "spec")

      expect(result[:ok]).to be true
      expect(result[:count]).to eq(1)
      expect(result[:records].first[:id]).to eq("Margherita")
    end

    it "answers one record when id is given" do
      result = described_class.state(runtime: runtime, aggregate: "Order", id: "Margherita", summary: "spec")

      expect(result[:ok]).to be true
      expect(result[:record][:id]).to eq("Margherita")
    end

    it "refuses an id that names no record" do
      result = described_class.state(runtime: runtime, aggregate: "Order", id: "Nope", summary: "spec")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("no Order found")
    end

    it "refuses an aggregate the domain never declared" do
      result = described_class.state(runtime: runtime, aggregate: "Calzone", summary: "spec")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("declares no aggregate")
    end
  end

  describe ".catalog" do
    it "lists every aggregate and the commands/queries each answers to" do
      result = described_class.catalog(runtime: runtime)

      expect(result[:ok]).to be true
      expect(result[:domain]).to eq("Pizzas")
      order = result[:aggregates].find { |a| a[:name] == "Order" }
      expect(order[:commands]).to include("create_pizza!", "purchase!")
      expect(order[:queries]).to include("available")
    end
  end

  describe ".describe" do
    it "answers the whole chapter's usage document when aggregate is omitted" do
      result = described_class.describe(runtime: runtime)

      expect(result[:ok]).to be true
      expect(result[:docs]).to include("Order")
    end

    it "narrows to one aggregate's contract" do
      result = described_class.describe(runtime: runtime, aggregate: "Order")

      expect(result[:ok]).to be true
      expect(result[:docs]).to include("CreatePizza")
    end

    it "refuses an aggregate the domain never declared" do
      result = described_class.describe(runtime: runtime, aggregate: "Calzone")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("declares no aggregate")
    end
  end

  describe ".validate" do
    it "answers valid: true for a domain whose wiring boots cleanly" do
      result = described_class.validate(domain: "examples/pizzas")

      expect(result).to eq(ok: true, domain: "examples/pizzas", valid: true)
    end

    it "answers valid: false, never a raised error, for a domain that cannot boot" do
      result = described_class.validate(domain: "examples/no_such_domain")

      expect(result[:ok]).to be false
      expect(result[:valid]).to be false
      expect(result[:error]).to be_a(String)
    end
  end
end
