require "spec_helper"

# WHAT THE DOMAIN FREEZES, ASSERTED AGAINST A REAL DISPATCH.
#
# Freezing has been fixed four times in four places — list attributes,
# the event log, query rows, value objects — and each fix topped the
# container and left the contents. `.freeze` on a Hash stops a key being
# added or removed and nothing else, so a caller reaches through and
# edits in place. Every one of those fixes looked complete.
#
# So this asks the question of a REAL result rather than a constructed
# one, and asks it about the whole reachable graph rather than the object
# on top.
RSpec.describe Hecksagain::Freezer do
  describe "the walk itself" do
    it "sees through a container that is frozen on top" do
      shallow = { name: +"mutable" }.freeze

      expect(shallow).to be_frozen
      expect(described_class.deeply_frozen?(shallow)).to be false
      expect(described_class.unfrozen_within(shallow)).to eq("name")
    end

    it "names the PATH to the first mutable thing, not merely that there is one" do
      # Frozen on top, mutable two levels down — the exact shape every
      # one of the four previous fixes left behind.
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

    # Immediates answer `frozen?` truthfully, but the walk should not
    # depend on that being true in every Ruby.
    it "treats immediates as already immune" do
      [nil, true, false, 1, 2.0, :sym].each do |held|
        expect(described_class.deeply_frozen?(held)).to be true
      end
    end
  end

  describe "a value object, after a real dispatch" do
    let(:result) do
      runtime = boot_in_memory
      runtime.dispatch("Pizzas::Order.CreatePizza",
                       name:  { value: "Margherita" },
                       pizza: { name: { value: "M" }, price_cents: { cents: 500 } })
    end

    # THE BUG THIS EXISTS FOR. `@fields.freeze` left the String inside a
    # value object mutable, so `vo[:value] << "!"` edited it in place —
    # demonstrated on a real dispatch, not supposed.
    # Asserted on the value object's OWN fields, not on `to_h` — that
    # answers a fresh hash by design, so its mutability says nothing
    # about the value it came from.
    it "is frozen through, not merely on top" do
      name = result.instance.state[:name]

      expect(name).to be_frozen
      expect(described_class.unfrozen_within(name.instance_variable_get(:@fields))).to be_nil
    end

    it "refuses a write reached through it" do
      name = result.instance.state[:name]

      expect { name[:value] << " MUTATED" }.to raise_error(FrozenError)
    end

    # A value object has no identity to change over, so the immutable
    # answer is a NEW one — which must itself be frozen through.
    it "answers a frozen value object from `with`" do
      grown = result.instance.state[:name].with(:value, "Napoli")

      expect(grown).to be_frozen
      expect(described_class.unfrozen_within(grown.instance_variable_get(:@fields))).to be_nil
    end
  end

  describe "an emitted event" do
    let(:runtime) { boot_in_memory }
    let(:event) do
      runtime.dispatch("Pizzas::Order.CreatePizza",
                       name:  { value: "Quattro" },
                       pizza: { name: { value: "M" }, price_cents: { cents: 500 } })
      runtime.events.last
    end

    # The domain fact the event carries. Freezing the payload Hash alone
    # would leave every value in it editable in place.
    it "carries a payload frozen through" do
      expect(described_class.unfrozen_within(event.payload)).to be_nil
    end

    it "refuses a write reached into the payload" do
      expect { event.payload[event.payload.keys.first] }.not_to raise_error
      expect { event.payload["forged"] = 1 }.to raise_error(FrozenError)
    end

    # The event ITSELF, not merely its payload. This could not be
    # asserted while correlation was merged onto already-emitted events;
    # it is set at construction now, because correlation is part of the
    # transaction and known before anything is emitted.
    it "is frozen once it exists" do
      expect(event).to be_frozen
      expect { event.name = "Forged" }.to raise_error(FrozenError)
    end

    # The log is not the events. New events are still recorded; it is
    # each one that stops changing.
    it "leaves the log itself appendable" do
      before = runtime.events.size
      runtime.dispatch("Pizzas::Order.CreatePizza",
                       name:  { value: "Capricciosa" },
                       pizza: { name: { value: "M" }, price_cents: { cents: 500 } })

      expect(runtime.events.size).to eq(before + 1)
    end
  end

  # THE WALK, POINTED AT A REAL DISPATCH. These are the three the QA
  # branch fixed and never landed — found by pointing `unfrozen_within`
  # at a booted domain rather than by reasoning about which paths exist.
  describe "collections the domain hands back" do
    let(:runtime) do
      rt = boot_in_memory
      rt.dispatch("Pizzas::Order.CreatePizza",
                  name:  { value: "Frozen" },
                  pizza: { name: { value: "M" }, price_cents: { cents: 500 } })
      rt
    end
    let(:aggregate)  { runtime.registry.bluebook("Pizzas").aggregate("Order") }
    let(:repository) { runtime.registry.repository("Pizzas", aggregate) }

    it "freezes an appended list through, not just the array" do
      runtime.dispatch("Pizzas::Order.AddTopping", name: "Frozen",
                       topping: { value: "Basil" }, amount: { value: 2 })
      toppings = repository.find("Frozen").state[:toppings]

      expect(described_class.unfrozen_within(toppings)).to be_nil
    end

    it "freezes what a query answers with" do
      rows = runtime.query("Pizzas::Order.Expensive")

      expect(described_class.unfrozen_within(rows)).to be_nil
    end

    # Every value ON a hydrated record, rather than the record's own
    # state holder — that stays mutable so a command can change it.
    it "freezes every value read back out of the store" do
      state = repository.find("Frozen").state

      state.each_value { |held| expect(described_class.unfrozen_within(held)).to be_nil }
    end
  end

  # NOT EVERYTHING IS FROZEN, and the exceptions are the point rather
  # than an oversight — a policy that froze the instance's own state
  # would refuse every command that changes anything.
  describe "what is deliberately NOT frozen" do
    it "leaves an instance's state holder mutable, since a command's job is to change it" do
      runtime = boot_in_memory
      result = runtime.dispatch("Pizzas::Order.CreatePizza",
                                name:  { value: "Marinara" },
                                pizza: { name: { value: "M" }, price_cents: { cents: 500 } })

      expect(result.instance.to_h).not_to be_frozen
    end
  end
end
