# emits_keyword_spec.rb — HEC-420
#
# Specs for the `emits` DSL keyword on commands. Covers:
# - Single explicit event name overriding inferred conjugation
# - Multiple events emitted per command
# - Backward compatibility when `emits` is not declared
# - Runtime: cmd.event, cmd.events after execution
# - Serializer round-trip
#
require "spec_helper"

RSpec.describe "emits keyword" do
  describe "single explicit event name" do
    let(:domain) do
      Hecks.domain "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String

          command "CreatePizza" do
            attribute :name, String
            emits "PizzaCreated"
          end
        end
      end
    end

    let!(:app) { Hecks.load(domain) }

    it "wires the named event instead of the inferred one" do
      expect(domain.aggregates.first.events.map(&:name)).to include("PizzaCreated")
      expect(domain.aggregates.first.events.map(&:name)).not_to include("CreatedPizza")
    end

    it "emits the named event at runtime" do
      PizzasDomain::Pizza.create(name: "Margherita")
      expect(app.events.size).to eq(1)
      expect(app.events.first.class.name).to match(/PizzaCreated/)
    end

    it "sets cmd.event to the emitted event" do
      cmd = PizzasDomain::Pizza.create(name: "Quattro")
      expect(cmd.event).not_to be_nil
      expect(cmd.event.class.name).to match(/PizzaCreated/)
    end

    it "sets cmd.events to an array with one event" do
      cmd = PizzasDomain::Pizza.create(name: "Quattro")
      expect(cmd.events).to be_an(Array)
      expect(cmd.events.size).to eq(1)
      expect(cmd.events.first).to eq(cmd.event)
    end
  end

  describe "multiple explicit event names" do
    let(:domain) do
      Hecks.domain "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String

          command "CreatePizza" do
            attribute :name, String
            emits "PizzaCreated", "MenuUpdated"
          end
        end
      end
    end

    let!(:app) { Hecks.load(domain) }

    it "generates both event classes" do
      event_names = domain.aggregates.first.events.map(&:name)
      expect(event_names).to include("PizzaCreated", "MenuUpdated")
    end

    it "emits all events at runtime" do
      PizzasDomain::Pizza.create(name: "Margherita")
      expect(app.events.size).to eq(2)
      event_class_names = app.events.map { |e| e.class.name }
      expect(event_class_names).to include(match(/PizzaCreated/), match(/MenuUpdated/))
    end

    it "sets cmd.event to the first event" do
      cmd = PizzasDomain::Pizza.create(name: "Napolitana")
      expect(cmd.event.class.name).to match(/PizzaCreated/)
    end

    it "sets cmd.events to all events" do
      cmd = PizzasDomain::Pizza.create(name: "Napolitana")
      expect(cmd.events.size).to eq(2)
      class_names = cmd.events.map { |e| e.class.name }
      expect(class_names).to include(match(/PizzaCreated/), match(/MenuUpdated/))
    end

    it "fires subscribers for each event" do
      received = []
      app.event_bus.subscribe("PizzaCreated") { |e| received << e.class.name.split("::").last }
      app.event_bus.subscribe("MenuUpdated") { |e| received << e.class.name.split("::").last }
      PizzasDomain::Pizza.create(name: "Romana")
      expect(received).to include("PizzaCreated", "MenuUpdated")
    end
  end

  describe "backward compatibility (no emits declared)" do
    let(:domain) do
      Hecks.domain "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String
          command "CreatePizza" do
            attribute :name, String
          end
        end
      end
    end

    let!(:app) { Hecks.load(domain) }

    it "still emits the inferred event" do
      PizzasDomain::Pizza.create(name: "Margherita")
      expect(app.events.size).to eq(1)
      expect(app.events.first.class.name).to match(/CreatedPizza/)
    end

    it "cmd.events has one entry equal to cmd.event" do
      cmd = PizzasDomain::Pizza.create(name: "Margherita")
      expect(cmd.events).to eq([cmd.event])
    end
  end

  describe "DSL serializer round-trip" do
    it "outputs emits line for single explicit name" do
      domain = Hecks.domain "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String
          command "CreatePizza" do
            attribute :name, String
            emits "PizzaCreated"
          end
        end
      end
      source = Hecks::DslSerializer.new(domain).serialize
      expect(source).to include('emits "PizzaCreated"')
    end

    it "outputs emits line with multiple names" do
      domain = Hecks.domain "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String
          command "CreatePizza" do
            attribute :name, String
            emits "PizzaCreated", "MenuUpdated"
          end
        end
      end
      source = Hecks::DslSerializer.new(domain).serialize
      expect(source).to include('emits "PizzaCreated", "MenuUpdated"')
    end

    it "omits emits line when not declared" do
      domain = Hecks.domain "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String
          command "CreatePizza" do
            attribute :name, String
          end
        end
      end
      source = Hecks::DslSerializer.new(domain).serialize
      expect(source).not_to include("emits")
    end
  end

  describe "policy reacts to named event" do
    let(:domain) do
      Hecks.domain "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String
          attribute :status, String

          command "CreatePizza" do
            attribute :name, String
            emits "PizzaCreated"
          end

          command "MarkReady" do
            attribute :pizza_id, String
          end

          policy "AutoReady" do
            on "PizzaCreated"
            trigger "MarkReady"
          end
        end
      end
    end

    let!(:app) { Hecks.load(domain) }

    it "triggers the policy when the named event fires" do
      PizzasDomain::Pizza.create(name: "Margherita")
      expect(app.events.size).to be >= 2
      event_class_names = app.events.map { |e| e.class.name }
      expect(event_class_names).to include(match(/PizzaCreated/), match(/MarkedReady/))
    end
  end
end
