require "spec_helper"

# What the domain freezes, asserted against a real dispatch.
#
# `.freeze` on a Hash leaves its contents editable, so each example walks the
# whole reachable graph of a real result rather than only its top object.
RSpec.describe Hecks::Freezer do
  describe "the walk itself" do
    it "sees through a container that is frozen on top" do
      shallow = { name: +"mutable" }.freeze

      expect(shallow).to be_frozen
      expect(described_class.deeply_frozen?(shallow)).to be false
      expect(described_class.unfrozen_within(shallow)).to eq("name")
    end

    it "names the PATH to the first mutable thing, not merely that there is one" do
      # frozen on top, mutable two levels down
      nested = { order: { pizzas: [{ name: +"m" }].freeze }.freeze }.freeze

      expect(described_class.unfrozen_within(nested)).to eq("order.pizzas.0")
      expect(described_class.unfrozen_within(described_class.deep(nested))).to be_nil
    end

    it "says so plainly when the top itself is the mutable thing" do
      expect(described_class.unfrozen_within({ a: 1 })).to eq("(the value itself)")
    end

    it "walks a list's elements, not just the list" do
      list = [+"a", +"b"]
      described_class.deep(list)

      expect(list).to all(be_frozen)
    end

    # The walk must not rely on immediates answering `frozen?` in every Ruby.
    it "treats immediates as already immune" do
      [nil, true, false, 1, 2.0, :sym].each do |held|
        expect(described_class.deeply_frozen?(held)).to be true
      end
    end
  end

  describe "a value object, after a real dispatch" do
    let(:result) do
      runtime = boot_in_memory
      runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                            name:  { value: "Margherita" },
                            pizza: { price_cents: { cents: 500 }, size: { value: "small" } })
    end

    # Regression: `@fields.freeze` left the String inside mutable. Asserted on
    # `@fields`, not `to_h`, which answers a fresh hash.
    it "is frozen through, not merely on top" do
      name = result.instance.state[:name]

      expect(name).to be_frozen
      expect(described_class.unfrozen_within(name.instance_variable_get(:@fields))).to be_nil
    end

    it "refuses a write reached through it" do
      name = result.instance.state[:name]

      expect { name[:value] << " MUTATED" }.to raise_error(FrozenError)
    end

    # The new value object must itself be frozen through.
    it "answers a frozen value object from `with`" do
      grown = result.instance.state[:name].with(:value, "Napoli")

      expect(grown).to be_frozen
      expect(described_class.unfrozen_within(grown.instance_variable_get(:@fields))).to be_nil
    end
  end

  describe "an emitted event" do
    let(:runtime) { boot_in_memory }
    let(:event) do
      runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                            name:  { value: "Quattro" },
                            pizza: { price_cents: { cents: 500 }, size: { value: "small" } })
      runtime.events.last
    end

    # Freezing the payload Hash alone would leave its values editable.
    it "carries a payload frozen through" do
      expect(described_class.unfrozen_within(event.payload)).to be_nil
    end

    it "refuses a write reached into the payload" do
      expect { event.payload[event.payload.keys.first] }.not_to raise_error
      expect { event.payload["forged"] = 1 }.to raise_error(FrozenError)
    end

    # The event itself, not only its payload; correlation is set at construction.
    it "is frozen once it exists" do
      expect(event).to be_frozen
      expect { event.name = "Forged" }.to raise_error(FrozenError)
    end

    # The log stays appendable; only each event stops changing.
    it "leaves the log itself appendable" do
      before = runtime.events.size
      runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                            name:  { value: "Capricciosa" },
                            pizza: { price_cents: { cents: 500 }, size: { value: "small" } })

      expect(runtime.events.size).to eq(before + 1)
    end
  end

  # `unfrozen_within` pointed at a booted domain rather than at hand-built values.
  describe "collections the domain hands back" do
    let(:runtime) do
      rt = boot_in_memory
      rt.dispatch_flat("Pizzas::Order.CreatePizza",
                       name:  { value: "Frozen" },
                       pizza: { price_cents: { cents: 500 }, size: { value: "small" } })
      rt
    end
    let(:aggregate)  { runtime.registry.bluebook("Pizzas").aggregate("Order") }
    let(:repository) { runtime.registry.repository("Pizzas", aggregate) }

    it "freezes an appended list through, not just the array" do
      runtime.dispatch_flat("Pizzas::Order.AddTopping", name: "Frozen",
                       topping: { value: "Basil" }, amount: { value: 2 })
      toppings = repository.find("Frozen").state[:toppings]

      expect(described_class.unfrozen_within(toppings)).to be_nil
    end

    it "freezes what a query answers with" do
      rows = runtime.query("Pizzas::Order.Expensive")

      expect(described_class.unfrozen_within(rows)).to be_nil
    end

    # Each value, not the state holder, which stays mutable for commands.
    it "freezes every value read back out of the store" do
      state = repository.find("Frozen").state

      state.each_value { |held| expect(described_class.unfrozen_within(held)).to be_nil }
    end
  end

  # Freezing an instance's own state would refuse every command that changes it.
  describe "what is deliberately NOT frozen" do
    it "leaves an instance's state holder mutable, since a command's job is to change it" do
      runtime = boot_in_memory
      result = runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                                     name:  { value: "Marinara" },
                                     pizza: { price_cents: { cents: 500 }, size: { value: "small" } })

      expect(result.instance.to_h).not_to be_frozen
    end
  end
end
