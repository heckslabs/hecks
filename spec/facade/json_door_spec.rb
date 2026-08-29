require "spec_helper"

RSpec.describe Hecks::Facade::JsonDoor do
  # `described_class` reads exactly as `Hecks::Facade::JsonDoor`
  # throughout this file — no separate alias needed.
  let(:json_door) { described_class }

  # `boot_in_memory` (spec_helper.rb, `InMemoryDomain`) is the shared
  # Memory-adapter boot every spec in this suite already reaches for —
  # Pizzas::Order, rebound to Memory rather than a real adapter, matching
  # this codebase's standing preference that specs boot against Memory and
  # reserve real-adapter specs for testing that adapter itself.
  def order(_dispatcher)
    Pizzas::Order.create_pizza!(
      name:  { value: "Margherita" },
      pizza: { price_cents: { cents: 1200 }, size: { value: "large" } }
    )
  end

  describe ".aggregate" do
    it "resolves a domain module name and an aggregate name to the installed Facade class" do
      dispatcher = boot_in_memory

      expect(json_door.aggregate(dispatcher, "Pizzas", "Order")).to equal(Pizzas::Order)
    end

    it "raises Runtime::NotFound for a domain the registry never booted" do
      dispatcher = boot_in_memory

      expect { json_door.aggregate(dispatcher, "NoSuchDomain", "Order") }
        .to raise_error(Hecks::Runtime::NotFound, /NoSuchDomain/)
    end

    it "raises Runtime::NotFound for an aggregate the domain never declared" do
      dispatcher = boot_in_memory

      expect { json_door.aggregate(dispatcher, "Pizzas", "Calzone") }
        .to raise_error(Hecks::Runtime::NotFound, /Calzone/)
    end
  end

  describe ".creating_command" do
    it "names the one command an aggregate declares creates? for, snake_cased" do
      boot_in_memory

      expect(json_door.creating_command(Pizzas::Order)).to eq("create_pizza!")
    end

    it "raises Runtime::NotFound when the aggregate declares no creating command" do
      # A real corpus aggregate always has exactly one (the meta-domain
      # itself checks for it at boot) — so the "none" branch is proven
      # against a minimal stand-in shaped the same way `AggregateDoor`
      # shapes the real thing (`klass.ir.commands`, each answering
      # `creates?`), not a mock of Hecks's own classes.
      non_creating_command = Struct.new(:hecks_name) { def creates? = false }.new("Rename")
      ir = Struct.new(:hecks_name, :commands).new("Widget", [non_creating_command])
      klass = Struct.new(:ir).new(ir)

      expect { json_door.creating_command(klass) }
        .to raise_error(Hecks::Runtime::NotFound, /Widget/)
    end
  end

  describe ".validate_command!" do
    it "accepts a declared command name" do
      boot_in_memory

      expect(json_door.validate_command!(Pizzas::Order, "add_topping!")).to eq("add_topping!")
    end

    it "raises Runtime::NotFound for a name the aggregate never declared" do
      boot_in_memory

      expect { json_door.validate_command!(Pizzas::Order, "cancel_order") }
        .to raise_error(Hecks::Runtime::NotFound, /cancel_order/)
    end

    it "raises Runtime::NotFound for the creating command, which a Handle can never dispatch" do
      # `klass.commands` (AggregateDoor's own door-level list) includes the
      # creating command; a `Handle` in hand only ever defines singleton
      # methods for non-creating verbs (`Handle#define_verb_methods`). A
      # caller that got "create_pizza!" past this gate would go on to hit
      # a raw NoMethodError from `handle.public_send("create_pizza!")`
      # instead of the clean 404 this method exists to give — this pins
      # the gate refusing it here instead.
      boot_in_memory

      expect { json_door.validate_command!(Pizzas::Order, "create_pizza!") }
        .to raise_error(Hecks::Runtime::NotFound, /create_pizza!/)
    end
  end

  describe ".find!" do
    it "returns the found record" do
      dispatcher = boot_in_memory
      pizza = order(dispatcher)

      found = json_door.find!(Pizzas::Order, pizza.id)

      expect(found).to eq(pizza)
    end

    it "raises Runtime::NotFound rather than answering nil for a missing id" do
      boot_in_memory

      expect { json_door.find!(Pizzas::Order, "no-such-id") }
        .to raise_error(Hecks::Runtime::NotFound, /no-such-id/)
    end
  end

  describe ".deep_symbolize" do
    it "symbolizes hash keys and maps arrays, arbitrarily deep, leaving scalars alone" do
      parsed = {
        "pizza"    => { "price_cents" => { "cents" => 1200 }, "size" => { "value" => "large" } },
        "toppings" => [{ "name" => "basil", "amount" => 2 }, { "name" => "olives", "amount" => 1 }],
        "name"     => { "value" => "Margherita" }
      }

      result = json_door.deep_symbolize(parsed)

      expect(result).to eq(
        pizza:    { price_cents: { cents: 1200 }, size: { value: "large" } },
        toppings: [{ name: "basil", amount: 2 }, { name: "olives", amount: 1 }],
        name:     { value: "Margherita" }
      )
    end
  end

  describe ".materialize" do
    it "deep-unwraps a Handle's nested Runtime::Value fields to plain Ruby" do
      dispatcher = boot_in_memory
      pizza = order(dispatcher)

      result = json_door.materialize(pizza)

      expect(result).to eq(
        id:            pizza.id,
        name:          { value: "Margherita" },
        pizza:         { price_cents: { cents: 1200 }, size: { value: "large" } },
        toppings:      [],
        customer_name: nil,
        status:        "available"
      )
      # Not just equal in VALUE — nothing left is still a Runtime::Value,
      # two levels down (Order -> Pizza -> Price), which `#eq` alone
      # wouldn't catch since Runtime::Value defines `==` by content.
      expect(result[:pizza][:price_cents]).to be_a(Hash)
      expect(result[:pizza][:price_cents]).not_to be_a(Hecks::Runtime::Value)
    end

    it "deep-unwraps a plain state hash the same way, without needing a Handle" do
      dispatcher = boot_in_memory
      pizza = order(dispatcher)

      result = json_door.materialize(pizza.to_h)

      expect(result[:pizza]).to eq(price_cents: { cents: 1200 }, size: { value: "large" })
    end
  end

  describe ".command_request" do
    it "keeps an entity receiver outside the declared JSON facts" do
      request = json_door.command_request(
        '{"to":{"aggregate":"DOWNTOWN:12","entity":"2026-01-05:1"},"with":{"note":{"text":"Flagged"}}}',
        receiver: :entity
      )

      expect(request).to eq(
        to:   { aggregate: "DOWNTOWN:12", entity: "2026-01-05:1" },
        with: { note: { text: "Flagged" } }
      )
    end

    it "accepts legacy flat id as an aggregate receiver without leaking it into with" do
      request = json_door.command_request({ "id" => "Margherita", "topping" => "Basil", "amount" => 3 },
                                          receiver: :aggregate, legacy_receiver: :id)

      expect(request).to eq(to: "Margherita", with: { topping: "Basil", amount: 3 })
    end

    it "refuses loose facts beside an explicit JSON envelope" do
      expect do
        json_door.command_request({ "to" => "one", "with" => {}, "extra" => true }, receiver: :aggregate)
      end.to raise_error(Hecks::Runtime::TypeMismatch, /facts in with.*loose extra/)
    end
  end

  describe ".parse" do
    it "parses a raw JSON body string" do
      expect(json_door.parse('{"name":"Margherita","toppings":["basil"]}'))
        .to eq("name" => "Margherita", "toppings" => ["basil"])
    end

    it "propagates JSON::ParserError, undecorated, for malformed input" do
      expect { json_door.parse("{not valid json") }.to raise_error(JSON::ParserError)
    end
  end
end
