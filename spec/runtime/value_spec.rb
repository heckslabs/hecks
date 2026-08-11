require "hecksagain"

RSpec.describe Hecksagain::Runtime::Value do
  describe ".latest_by" do
    # A REAL list_of FIELD, not a synthetic array — `toppings` grows by
    # plain append (`AddTopping`), the exact shape `.latest_by` exists
    # for: nothing here erases the earlier "Basil, amount 3" when
    # "Basil, amount 5" gets added later, so reading the field's own
    # raw history back gives both rows, in order.
    let(:runtime) { boot_in_memory }

    def pizza_toppings
      pizza = runtime.dispatch("Pizzas::Order.CreatePizza", name: { value: "Margherita" },
                                pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
      runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 })
      runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 5 })
      runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Olive" }, amount: { value: 1 })
      repository.find(pizza.id).state[:toppings]
    end

    def repository = runtime.registry.repository("Pizzas", runtime.registry.bluebook("Pizzas").aggregate("Order"))

    it "keeps only the last row for each distinct key, in the order it last appeared" do
      reduced = described_class.latest_by(pizza_toppings, :name)

      expect(reduced.map { |row| [row.name, row.amount] }).to eq([["Basil", 5], ["Olive", 1]])
    end

    it "drops nothing when every key is already distinct" do
      rows = pizza_toppings.reject { |row| row.name == "Basil" && row.amount == 3 }

      expect(described_class.latest_by(rows, :name).map(&:name)).to contain_exactly("Basil", "Olive")
    end

    it "returns an empty array for an empty log" do
      expect(described_class.latest_by([], :name)).to eq([])
    end

    it "does not mutate or reorder the source rows" do
      rows = pizza_toppings
      original = rows.dup

      described_class.latest_by(rows, :name)

      expect(rows.map(&:to_h)).to eq(original.map(&:to_h))
    end

    # THE ACTUAL SHAPE THIS EXISTS FOR — an append-only sentinel field
    # (BurningManPrep's own `List#placements`, `position == -1` meaning
    # "removed"), proving the split holds: `.latest_by` only groups,
    # the caller supplies every bit of meaning on top.
    it "supports the append-only-log-with-a-removal-sentinel pattern, grouping only — the caller still interprets" do
      vo = pizza_toppings.first.value_object
      rows = [
        described_class.build(vo, { name: "headlamp", amount: 1 }),
        described_class.build(vo, { name: "stove", amount: 2 }),
        described_class.build(vo, { name: "headlamp", amount: -1 })
      ]

      current = described_class.latest_by(rows, :name).reject { |row| row.amount == -1 }

      expect(current.map(&:name)).to eq(["stove"])
    end
  end
end
