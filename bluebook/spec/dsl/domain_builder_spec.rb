require "spec_helper"

RSpec.describe Hecks::DSL::DomainBuilder do
  describe "aggregates" do
    it "builds domain with name and aggregates" do
      domain = Hecks.domain("Pizzas") { aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :name, String } } }
      expect(domain.name).to eq("Pizzas")
      expect(domain.aggregates.size).to eq(1)
      expect(domain.aggregates.first.name).to eq("Pizza")
      expect(domain.aggregates.first.attributes.first.name).to eq(:name)
      expect(domain.aggregates.first.attributes.first.type).to eq(String)
    end

    it "builds multiple aggregates" do
      domain = Hecks.domain("Inventory") do
        aggregate("Widget") { attribute :name, String; command("CreateWidget") { attribute :name, String } }
        aggregate("Gadget") { attribute :count, Integer; command("CreateGadget") { attribute :count, Integer } }
      end
      expect(domain.aggregates.map(&:name)).to eq(["Widget", "Gadget"])
    end

    describe "definition: kwarg" do
      it "stores definition as description on the aggregate IR" do
        domain = Hecks.domain("Pizzas") do
          aggregate "Pizza", definition: "A customizable food item with a crust, sauce, and toppings" do
            attribute :name, String
          end
        end
        expect(domain.aggregates.first.description).to eq("A customizable food item with a crust, sauce, and toppings")
      end

      it "leaves description nil when definition: is omitted" do
        domain = Hecks.domain("Pizzas") do
          aggregate "Pizza" do
            attribute :name, String
          end
        end
        expect(domain.aggregates.first.description).to be_nil
      end
    end
  end

  describe "commands and events" do
    it "infers past-tense event names" do
      domain = Hecks.domain("Pizzeria") { aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :name, String }; command("DeletePizza") { attribute :id, String } } }
      expect(domain.aggregates.first.events.map(&:name)).to eq(["CreatedPizza", "DeletedPizza"])
    end

    it "copies command and aggregate attributes to inferred event" do
      domain = Hecks.domain("Pizzeria") { aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :title, String; attribute :price, Float } } }
      event = domain.aggregates.first.events.first
      expect(event.attributes.map(&:name)).to eq([:aggregate_id, :title, :price, :name])
    end

    describe "emits keyword" do
      it "overrides the inferred event name with a single explicit name" do
        domain = Hecks.domain("Pizzeria") do
          aggregate("Pizza") do
            attribute :name, String
            command("CreatePizza") do
              attribute :name, String
              emits "PizzaCreated"
            end
          end
        end
        agg = domain.aggregates.first
        cmd = agg.commands.first
        expect(cmd.emits).to eq("PizzaCreated")
        expect(cmd.event_names).to eq(["PizzaCreated"])
        expect(agg.events.map(&:name)).to include("PizzaCreated")
        expect(agg.events.map(&:name)).not_to include("CreatedPizza")
      end

      it "produces multiple events for a command with multiple emits" do
        domain = Hecks.domain("Pizzeria") do
          aggregate("Pizza") do
            attribute :name, String
            command("CreatePizza") do
              attribute :name, String
              emits "PizzaCreated", "MenuUpdated"
            end
          end
        end
        agg = domain.aggregates.first
        cmd = agg.commands.first
        expect(cmd.event_names).to eq(["PizzaCreated", "MenuUpdated"])
        expect(agg.events.map(&:name)).to include("PizzaCreated", "MenuUpdated")
      end

      it "falls back to inferred event name when emits is not set" do
        domain = Hecks.domain("Pizzeria") do
          aggregate("Pizza") do
            attribute :name, String
            command("CreatePizza") { attribute :name, String }
          end
        end
        cmd = domain.aggregates.first.commands.first
        expect(cmd.event_names).to eq(["CreatedPizza"])
      end
    end
  end

  describe "queries" do
    it "stores query name and block" do
      domain = Hecks.domain("Devices") { aggregate("Device") { attribute :status, String; command("CreateDevice") { attribute :status, String }; query("Active") { where(status: "on") } } }
      q = domain.aggregates.first.queries.first
      expect(q.name).to eq("Active")
      expect(q.block).to be_a(Proc)
    end

    it "stores parameterized query blocks" do
      domain = Hecks.domain("Devices") { aggregate("Device") { attribute :status, String; command("CreateDevice") { attribute :status, String }; query("ByStatus") { |status| where(status: status) } } }
      q = domain.aggregates.first.queries.first
      expect(q.block.parameters).to eq([[:opt, :status]])
    end
  end

  describe "value objects" do
    it "stores VOs with attributes and invariants" do
      domain = Hecks.domain("Orders") do
        aggregate("Order") do
          attribute :items, list_of("Item")
          value_object("Item") { attribute :qty, Integer; invariant("must be positive") { qty > 0 } }
          command("CreateOrder") { attribute :name, String }
        end
      end
      vo = domain.aggregates.first.value_objects.first
      expect(vo.name).to eq("Item")
      expect(vo.attributes.first.name).to eq(:qty)
      expect(vo.invariants.size).to eq(1)
      expect(vo.invariants.first.message).to eq("must be positive")
    end
  end

  describe "policies" do
    it "stores event and trigger command" do
      domain = Hecks.domain("Workflow") do
        aggregate("Task") { attribute :name, String; command("CreateTask") { attribute :name, String }; command("ProcessTask") { attribute :name, String }; policy("React") { on "CreatedTask"; trigger "ProcessTask" } }
      end
      pol = domain.aggregates.first.policies.first
      expect(pol.name).to eq("React")
      expect(pol.event_name).to eq("CreatedTask")
      expect(pol.trigger_command).to eq("ProcessTask")
    end
  end

  describe "validations" do
    it "stores field and rules" do
      domain = Hecks.domain("Pizzeria") { aggregate("Pizza") { attribute :name, String; validation(:name, presence: true); command("CreatePizza") { attribute :name, String } } }
      val = domain.aggregates.first.validations.first
      expect(val.field).to eq(:name)
      expect(val.presence?).to be true
    end
  end

  describe "scopes" do
    it "stores hash scopes" do
      domain = Hecks.domain("Devices") { aggregate("Device") { attribute :status, String; command("CreateDevice") { attribute :status, String }; scope(:active, status: "on") } }
      scope = domain.aggregates.first.scopes.first
      expect(scope.name).to eq(:active)
      expect(scope.callable?).to be false
    end

    it "stores lambda scopes" do
      domain = Hecks.domain("Devices") { aggregate("Device") { attribute :status, String; command("CreateDevice") { attribute :status, String }; scope(:by_status, ->(val) { { status: val } }) } }
      scope = domain.aggregates.first.scopes.first
      expect(scope.callable?).to be true
      expect(scope.conditions.call("x")).to eq({ status: "x" })
    end
  end

  describe "attribute types" do
    it "supports String, Integer, Float" do
      domain = Hecks.domain("Types") { aggregate("Widget") { attribute :label, String; attribute :count, Integer; attribute :price, Float; command("CreateWidget") { attribute :label, String } } }
      types = domain.aggregates.first.attributes.map(&:type)
      expect(types).to eq([String, Integer, Float])
    end

    it "supports JSON" do
      domain = Hecks.domain("Types") { aggregate("Widget") { attribute :data, JSON; command("CreateWidget") { attribute :data, JSON } } }
      expect(domain.aggregates.first.attributes.first.json?).to be true
    end

    it "supports reference_to" do
      domain = Hecks.domain("Types") do
        aggregate("Widget") { attribute :name, String; command("CreateWidget") { attribute :name, String } }
        aggregate("Part") { reference_to "Widget"; command("CreatePart") { reference_to "Widget" } }
      end
      ref = domain.aggregates.last.references.first
      expect(ref).not_to be_nil
      expect(ref.type).to eq("Widget")
    end

    it "supports list_of" do
      domain = Hecks.domain("Types") { aggregate("Widget") { attribute :items, list_of("Item"); command("CreateWidget") { attribute :name, String } } }
      attr = domain.aggregates.first.attributes.first
      expect(attr.list?).to be true
    end

    it "supports lifecycle block on attribute" do
      domain = Hecks.domain("Lifecycle") do
        aggregate("Ticket") do
          attribute :title, String
          attribute :status, String, default: "open" do
            transition "StartTicket" => "in_progress", from: "open"
            transition "CloseTicket" => "closed", from: "in_progress"
          end
          command("CreateTicket") { attribute :title, String }
          command("StartTicket") { reference_to "Ticket" }
          command("CloseTicket") { reference_to "Ticket" }
        end
      end
      agg = domain.aggregates.first
      expect(agg.lifecycle).not_to be_nil
      expect(agg.lifecycle.field).to eq(:status)
      expect(agg.lifecycle.default).to eq("open")
      expect(agg.lifecycle.target_for("StartTicket")).to eq("in_progress")
      expect(agg.lifecycle.target_for("CloseTicket")).to eq("closed")
    end

    it "supports identity for composed natural keys" do
      domain = Hecks.domain("Identity") do
        aggregate("TeamCycle") do
          attribute :team, String
          attribute :start_date, Date
          identity :team, :start_date
          command("CreateTeamCycle") { attribute :team, String; attribute :start_date, Date }
        end
      end
      agg = domain.aggregates.first
      expect(agg.identity_fields).to eq([:team, :start_date])
    end

    it "identity_fields defaults to nil" do
      domain = Hecks.domain("NoIdentity") do
        aggregate("Thing") { attribute :name, String; command("CreateThing") { attribute :name, String } }
      end
      expect(domain.aggregates.first.identity_fields).to be_nil
    end
  end

  describe "domain metadata" do
    it "generates gem_name from domain name" do
      expect(Hecks.domain("Pizza Shop") { aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :name, String } } }.gem_name).to eq("pizza_shop_domain")
    end

    it "generates module_name from domain name" do
      expect(Hecks.domain("Pizza Shop") { aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :name, String } } }.module_name).to eq("PizzaShop")
    end

    it "source_path is settable" do
      domain = Hecks.domain("Metadata") { aggregate("Pizza") { attribute :name, String; command("CreatePizza") { attribute :name, String } } }
      domain.source_path = "/tmp/test.rb"
      expect(domain.source_path).to eq("/tmp/test.rb")
    end
  end

  describe "domain-level actors" do
    it "stores actors on the domain" do
      domain = Hecks.domain("Gov") do
        actor "governance_board"
        actor "admin", description: "System administrator"
        aggregate("Policy") { attribute :name, String; command("CreatePolicy") { attribute :name, String } }
      end
      expect(domain.actors.length).to eq(2)
      expect(domain.actors[0].name).to eq("governance_board")
      expect(domain.actors[0].description).to be_nil
      expect(domain.actors[1].name).to eq("admin")
      expect(domain.actors[1].description).to eq("System administrator")
    end
  end

  describe "reference classification" do
    it "classifies local entity/VO references as composition" do
      domain = Hecks.domain("Shop") do
        aggregate("Order") do
          attribute :name, String
          entity("LineItem") { attribute :qty, Integer }
          reference_to "LineItem"
          command("CreateOrder") { attribute :name, String }
        end
      end
      ref = domain.aggregates.first.references.find { |r| r.type == "LineItem" }
      expect(ref.kind).to eq(:composition)
    end

    it "classifies aggregate root references as aggregation" do
      domain = Hecks.domain("Shop") do
        aggregate("Order") do
          attribute :name, String
          reference_to "Customer"
          command("CreateOrder") { attribute :name, String }
        end
        aggregate("Customer") { attribute :name, String; command("CreateCustomer") { attribute :name, String } }
      end
      ref = domain.aggregates.first.references.find { |r| r.type == "Customer" }
      expect(ref.kind).to eq(:aggregation)
    end

    it "classifies :: paths as cross-context" do
      domain = Hecks.domain("Shop") do
        aggregate("Order") do
          attribute :name, String
          reference_to "Billing::Invoice"
          command("CreateOrder") { attribute :name, String }
        end
      end
      ref = domain.aggregates.first.references.find { |r| r.type == "Invoice" }
      expect(ref.kind).to eq(:cross_context)
      expect(ref.domain).to eq("Billing")
    end
  end

  describe "aggregate definition keyword" do
    it "stores definition via definition: kwarg" do
      domain = Hecks.domain("Banking") do
        aggregate "Account", definition: "Manages customer funds and balances" do
          attribute :name, String
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.description).to eq("Manages customer funds and balances")
    end

    it "stores definition via positional description" do
      domain = Hecks.domain("Banking") do
        aggregate "Account", "Manages customer funds" do
          attribute :name, String
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.description).to eq("Manages customer funds")
    end

    it "definition: kwarg takes precedence over positional description" do
      domain = Hecks.domain("Banking") do
        aggregate "Account", "positional", definition: "kwarg wins" do
          attribute :name, String
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.description).to eq("kwarg wins")
    end

    it "works with implicit PascalCase syntax" do
      domain = Hecks.domain("Banking") do
        Account definition: "Manages customer funds" do
          attribute :name, String
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.description).to eq("Manages customer funds")
    end

    it "returns nil when no definition is provided" do
      domain = Hecks.domain("Banking") do
        aggregate "Account" do
          attribute :name, String
          command("CreateAccount") { attribute :name, String }
        end
      end
      expect(domain.aggregates.first.description).to be_nil
    end
  end

  describe "explicit domain events" do
    it "includes explicit events alongside inferred ones" do
      domain = Hecks.domain("Gov") do
        aggregate("Policy") do
          attribute :name, String
          event("PolicyExpired") { attribute :policy_id, String }
          command("CreatePolicy") { attribute :name, String }
        end
      end
      events = domain.aggregates.first.events.map(&:name)
      expect(events).to include("CreatedPolicy")
      expect(events).to include("PolicyExpired")
    end

    it "explicit event overrides inferred event with same name" do
      domain = Hecks.domain("Gov") do
        aggregate("Policy") do
          attribute :name, String
          event("CreatedPolicy") { attribute :custom_field, String }
          command("CreatePolicy") { attribute :name, String }
        end
      end
      event = domain.aggregates.first.events.find { |e| e.name == "CreatedPolicy" }
      expect(event.attributes.map(&:name)).to include(:custom_field)
    end
  end
end
