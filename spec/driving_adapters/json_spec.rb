require "spec_helper"

RSpec.describe Hecks::Adapters::Driving::Json do
  let(:json) { described_class }

  # Pizzas::Order booted against Memory via `boot_in_memory`.
  def order(_dispatcher)
    Pizzas::Order.create_pizza!(
      name:  { value: "Margherita" },
      pizza: { price_cents: { cents: 1200 }, size: { value: "large" } }
    )
  end

  describe ".aggregate" do
    it "resolves a domain module name and an aggregate name to the installed entry point class" do
      dispatcher = boot_in_memory

      expect(json.aggregate(dispatcher, "Pizzas", "Order")).to equal(Pizzas::Order)
    end

    it "raises Runtime::NotFound for a domain the registry never booted" do
      dispatcher = boot_in_memory

      expect { json.aggregate(dispatcher, "NoSuchDomain", "Order") }
        .to raise_error(Hecks::Runtime::NotFound, /NoSuchDomain/)
    end

    it "raises Runtime::NotFound for an aggregate the domain never declared" do
      dispatcher = boot_in_memory

      expect { json.aggregate(dispatcher, "Pizzas", "Calzone") }
        .to raise_error(Hecks::Runtime::NotFound, /Calzone/)
    end
  end

  describe ".creating_command" do
    it "names the one command an aggregate declares creates? for, snake_cased" do
      boot_in_memory

      expect(json.creating_command(Pizzas::Order)).to eq("create_pizza!")
    end

    it "raises Runtime::NotFound when the aggregate declares no creating command" do
      # Every corpus aggregate has a creating command, so the "none" branch
      # needs a minimal stand-in shaped like `klass.ir.commands` (each answering `creates?`).
      non_creating_command = Struct.new(:hecks_name) { def creates? = false }.new("Rename")
      ir = Struct.new(:hecks_name, :commands).new("Widget", [non_creating_command])
      klass = Struct.new(:ir).new(ir)

      expect { json.creating_command(klass) }
        .to raise_error(Hecks::Runtime::NotFound, /Widget/)
    end
  end

  describe ".validate_command!" do
    it "accepts a declared command name" do
      boot_in_memory

      expect(json.validate_command!(Pizzas::Order, "add_topping!")).to eq("add_topping!")
    end

    it "raises Runtime::NotFound for a name the aggregate never declared" do
      boot_in_memory

      expect { json.validate_command!(Pizzas::Order, "cancel_order") }
        .to raise_error(Hecks::Runtime::NotFound, /cancel_order/)
    end

    it "raises Runtime::NotFound for the creating command, which a Handle can never dispatch" do
      # A Handle only defines methods for non-creating verbs, so letting "create_pizza!"
      # through would surface a raw NoMethodError instead of the clean 404.
      boot_in_memory

      expect { json.validate_command!(Pizzas::Order, "create_pizza!") }
        .to raise_error(Hecks::Runtime::NotFound, /create_pizza!/)
    end
  end

  describe ".find!" do
    it "returns the found record" do
      dispatcher = boot_in_memory
      pizza = order(dispatcher)

      found = json.find!(Pizzas::Order, pizza.id)

      expect(found).to eq(pizza)
    end

    it "raises Runtime::NotFound rather than answering nil for a missing id" do
      boot_in_memory

      expect { json.find!(Pizzas::Order, "no-such-id") }
        .to raise_error(Hecks::Runtime::NotFound, /no-such-id/)
    end
  end

  describe ".deep_symbolize" do
    let(:parsed) do
      {
        "pizza"    => { "price_cents" => { "cents" => 1200 }, "size" => { "value" => "large" } },
        "toppings" => [{ "name" => "basil", "amount" => 2 }, { "name" => "olives", "amount" => 1 }],
        "name"     => { "value" => "Margherita" }
      }
    end

    let(:symbolized) do
      {
        pizza:    { price_cents: { cents: 1200 }, size: { value: "large" } },
        toppings: [{ name: "basil", amount: 2 }, { name: "olives", amount: 1 }],
        name:     { value: "Margherita" }
      }
    end

    it "symbolizes hash keys and maps arrays, arbitrarily deep, leaving scalars alone" do
      expect(json.deep_symbolize(parsed)).to eq(symbolized)
    end
  end

  describe ".materialize" do
    def margherita_state(pizza)
      { id:            pizza.id,
        name:          { value: "Margherita" },
        pizza:         { price_cents: { cents: 1200 }, size: { value: "large" } },
        toppings:      [],
        customer_name: nil,
        status:        "available" }
    end

    it "deep-unwraps a Handle's nested Runtime::Value fields to plain Ruby", :aggregate_failures do
      pizza = order(boot_in_memory)
      result = json.materialize(pizza)

      expect(result).to eq(margherita_state(pizza))
      # `eq` alone misses a leftover Runtime::Value, which compares equal by content.
      expect(result[:pizza][:price_cents]).to be_a(Hash)
      expect(result[:pizza][:price_cents]).not_to be_a(Hecks::Runtime::Value)
    end

    it "deep-unwraps a plain state hash the same way, without needing a Handle" do
      dispatcher = boot_in_memory
      pizza = order(dispatcher)

      result = json.materialize(pizza.to_h)

      expect(result[:pizza]).to eq(price_cents: { cents: 1200 }, size: { value: "large" })
    end
  end

  describe ".command_request" do
    let(:entity_envelope) do
      '{"to":{"aggregate":"DOWNTOWN:12","entity":"2026-01-05:1"},"with":{"note":{"text":"Flagged"}}}'
    end

    it "keeps an entity receiver outside the declared JSON facts" do
      request = json.command_request(entity_envelope, receiver: :entity)

      expect(request).to eq(
        to:   { aggregate: "DOWNTOWN:12", entity: "2026-01-05:1" },
        with: { note: { text: "Flagged" } }
      )
    end

    it "accepts legacy flat id as an aggregate receiver without leaking it into with" do
      request = json.command_request({ "id" => "Margherita", "topping" => "Basil", "amount" => 3 },
                                     receiver: :aggregate, legacy_receiver: :id)

      expect(request).to eq(to: "Margherita", with: { topping: "Basil", amount: 3 })
    end

    it "refuses loose facts beside an explicit JSON envelope" do
      expect do
        json.command_request({ "to" => "one", "with" => {}, "extra" => true }, receiver: :aggregate)
      end.to raise_error(Hecks::Runtime::TypeMismatch, /facts in with.*loose extra/)
    end
  end
end
