require "hecks"

RSpec.describe Hecks::Runtime::Value do
  describe ".latest_by" do
    # `toppings` grows by plain append, so its raw history keeps both Basil rows in order.
    let(:runtime) { boot_in_memory }

    def pizza_toppings
      pizza = runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                                    name:  { value: "Margherita" },
                                    pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })
      runtime.dispatch_flat("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 })
      runtime.dispatch_flat("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 5 })
      runtime.dispatch_flat("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Olive" }, amount: { value: 1 })
      repository.find(pizza.id).state[:toppings]
    end

    # An append-only log: a later row with `amount: -1` is a removal sentinel for its key.
    def removal_log_rows
      value_object = pizza_toppings.first.value_object
      [{ name: "headlamp", amount: 1 }, { name: "stove", amount: 2 }, { name: "headlamp", amount: -1 }]
        .map { |facts| described_class.build(value_object, facts) }
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

    # The append-only log with a removal sentinel (`position == -1`): `.latest_by` only
    # groups, the caller supplies the meaning.
    it "supports the append-only-log-with-a-removal-sentinel pattern, grouping only — the caller still interprets" do
      current = described_class.latest_by(removal_log_rows, :name).reject { |row| row.amount == -1 }

      expect(current.map(&:name)).to eq(["stove"])
    end
  end

  # A stored `false` in a dotted identity path must not read as nil, which would fail
  # the whole identity.
  describe ".reference_identity" do
    # Minimal doubles: only `identity_paths` is read on this path.
    ReferenceIdentityFakeType      = Struct.new(:target) { def resolve = target } unless defined?(ReferenceIdentityFakeType)
    ReferenceIdentityFakeTarget    = Struct.new(:identity_paths) unless defined?(ReferenceIdentityFakeTarget)
    ReferenceIdentityFakeAttribute = Struct.new(:type) unless defined?(ReferenceIdentityFakeAttribute)

    def reference_attribute(paths)
      ReferenceIdentityFakeAttribute.new(ReferenceIdentityFakeType.new(ReferenceIdentityFakeTarget.new(paths)))
    end

    it "resolves a false-valued dotted identity member to its real value, not nil" do
      attribute = reference_attribute(["flags.active"])

      expect(described_class.reference_identity(attribute, { flags: { active: false } })).to eq("false")
    end

    it "still resolves a true-valued dotted identity member" do
      attribute = reference_attribute(["flags.active"])

      expect(described_class.reference_identity(attribute, { flags: { active: true } })).to eq("true")
    end

    it "still hands the raw value back when a genuine part is absent" do
      attribute = reference_attribute(["flags.active"])

      expect(described_class.reference_identity(attribute, { flags: {} })).to eq({ flags: {} })
    end
  end
end
