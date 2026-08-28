require "spec_helper"

# "SINGLE-ELEMENT VALUE OBJECTS STRICTLY ANSWER `.value`" — the three
# halves of one language rule, asserted together because they only mean
# anything together:
#
#   1. the bare DSL shorthand — `value_object "Price", Integer` declares
#      exactly one attribute, NAMED `value`, of that type (sugar for the
#      block form's single `attribute :value, Type` line;
#      `AggregateBuilder#value_object`'s own comment);
#   2. the runtime alias — ANY value object with exactly one declared
#      attribute answers `.value`, whatever that attribute is actually
#      named (`Runtime::Value#method_missing` / `#resolve_field`), and a
#      multi-attribute one keeps its refusal (there is no single value
#      `.value` could honestly mean);
#   3. call-site collapsing — a bare scalar offered where a
#      single-attribute value object is declared wraps into that value
#      object's own REAL field automatically
#      (`Runtime::Value::Coercion#fields_for`'s count-one auto-wrap),
#      while the explicit `{real_field: x}` spelling keeps working
#      unchanged.
#
# The fixture (spec/fixtures/scalar_value_objects.bluebook — also a
# parser-parity corpus member, so the Rust parser byte-matches the same
# shapes) carries one of each declaration: a shorthand-declared
# `StickerRef{value}`, a shorthand `Shelf{value}` (Integer), and a
# block-form `Price{amount}` whose author picked a domain name.
RSpec.describe "single-element value objects strictly answer .value" do
  SCALAR_VO_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/scalar_value_objects.bluebook")

  def boot_stickers
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(SCALAR_VO_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def sticker_aggregate
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(SCALAR_VO_BLUEBOOK)
    end
    registry.bluebook("ScalarValueObjects").aggregate("Sticker")
  end

  describe "the bare value_object shorthand" do
    it "declares exactly one attribute, named value, of the given type" do
      shape = sticker_aggregate.value_object("StickerRef")

      expect(shape.attributes.map { |a| [a.name, a.type.to_s, a.list?, a.optional?] })
        .to eq([[:value, "String", false, false]])
    end

    it "is byte-equivalent sugar for the block form's own attribute :value line" do
      aggregate = sticker_aggregate
      shorthand = aggregate.value_object("Shelf").to_h
      spelled   = Hecks::Bluebook::ValueObject.declare(
        name:       "Shelf",
        attributes: [Hecks::Bluebook::Attribute.new(name: :value, type: "Integer")]
      ).to_h

      expect(shorthand).to eq(spelled)
    end

    it "refuses a type AND a block together — two answers to one question" do
      expect do
        Hecks::Bluebook::DSL::ConstShim.with(->(const) { const }) do
          Hecks::Bluebook::DSL::AggregateBuilder.build("Bad") do
            value_object("X", String) { attribute :y, Integer }
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares both a type .* and a block/)
    end

    it "keeps today's behavior for neither type nor block: an empty attribute list" do
      # Pinned deliberately, not endorsed — whatever downstream judges
      # make of an attributeless value object is their business; the
      # shorthand must not change what this spelling has always built.
      aggregate = Hecks::Bluebook::DSL::ConstShim.with(->(const) { const }) do
        Hecks::Bluebook::DSL::AggregateBuilder.build("Bare") { value_object "Empty" }
      end

      expect(aggregate.value_object("Empty").attributes).to eq([])
    end
  end

  describe "Runtime::Value's .value alias" do
    def value_of(type, fields)
      Hecks::Runtime::Value.build(sticker_aggregate.value_object(type), fields)
    end

    it "answers the sole attribute when it is literally named value" do
      expect(value_of("StickerRef", { value: "S1" }).value).to eq("S1")
    end

    it "answers the sole attribute whatever it is actually named" do
      price = value_of("Price", { amount: 7 })

      expect(price.value).to eq(7)
      expect(price.amount).to eq(7)
      expect(price.respond_to?(:value)).to be(true)
    end

    it "aliases indexed reads and key? the same way" do
      price = value_of("Price", { amount: 7 })

      expect(price[:value]).to eq(7)
      expect(price["value"]).to eq(7)
      expect(price.key?(:value)).to be(true)
    end

    it "writes through the alias into the REAL field — with(:value, x) never mints a :value key" do
      expect(value_of("Price", { amount: 7 }).with(:value, 9).to_h).to eq(amount: 9)
    end

    it "serializes under the real field name, not the alias" do
      expect(value_of("Price", { amount: 7 }).to_h).to eq(amount: 7)
      expect(value_of("Price", { amount: 7 }).to_json).to eq('{"amount":7}')
    end

    it "keeps the multi-attribute refusal: .value stays a NoMethodError" do
      pair = Hecks::Runtime::Value.build(
        Hecks::Bluebook::ValueObject.declare(
          name:       "Pair",
          attributes: [Hecks::Bluebook::Attribute.new(name: :a, type: "String"),
                       Hecks::Bluebook::Attribute.new(name: :b, type: "String")]
        ),
        { a: "x", b: "y" }
      )

      expect { pair.value }.to raise_error(NoMethodError)
      expect(pair.respond_to?(:value)).to be(false)
      expect(pair[:value]).to be_nil
      expect(pair.key?(:value)).to be(false)
    end
  end

  describe "call-site scalar collapsing" do
    it "collapses a bare scalar into the sole field, real name and shorthand name alike" do
      runtime = boot_stickers
      runtime.dispatch("ScalarValueObjects::Sticker.Print", ref: "S1", price: 7)

      sticker = ScalarValueObjects::Sticker.find("S1")
      expect(sticker.ref.to_h).to eq(value: "S1")
      expect(sticker.price.to_h).to eq(amount: 7)
      expect(sticker.price.value).to eq(7)
    end

    it "keeps the explicit field-named spelling working unchanged" do
      runtime = boot_stickers
      runtime.dispatch("ScalarValueObjects::Sticker.Print", ref: { value: "S2" }, price: { amount: 3 })

      expect(ScalarValueObjects::Sticker.find("S2").price.to_h).to eq(amount: 3)
    end

    it "collapses through a mutation too" do
      runtime = boot_stickers
      runtime.dispatch("ScalarValueObjects::Sticker.Print", ref: "S3", price: 1)
      runtime.dispatch("ScalarValueObjects::Sticker.Reprice", sticker: "S3", price: 12)

      expect(ScalarValueObjects::Sticker.find("S3").price.value).to eq(12)
    end

    it "still refuses a bare scalar for a genuinely multi-field value object" do
      runtime = boot_stickers
      runtime.dispatch("ScalarValueObjects::Sticker.Print", ref: "S4", price: 2)

      # The fixture has no multi-field command argument on purpose (its
      # whole point is single-attribute shapes) — the refusal is pinned
      # at the coercion door directly instead, against an ad-hoc
      # two-field shape, so the auto-wrap provably stays count-gated.
      two_field = Hecks::Bluebook::ValueObject.declare(
        name:       "Range",
        attributes: [Hecks::Bluebook::Attribute.new(name: :lo, type: "Integer"),
                     Hecks::Bluebook::Attribute.new(name: :hi, type: "Integer")]
      )
      expect { Hecks::Runtime::Value.fields_for(two_field, :range, 5) }
        .to raise_error(Hecks::Runtime::TypeMismatch)
    end

    it "answers a bare-field query over each single-attribute shape" do
      runtime = boot_stickers
      runtime.dispatch("ScalarValueObjects::Sticker.Print", ref: "S5", price: 40)
      runtime.dispatch("ScalarValueObjects::Sticker.Print", ref: "S6", price: 50)

      at_forty = runtime.query("ScalarValueObjects::Sticker.AtPrice", price: 40)
      expect(at_forty.map { |row| row[:ref].value }).to eq(["S5"])

      by_ref = runtime.query("ScalarValueObjects::Sticker.ByRef", ref: "S6")
      expect(by_ref.map { |row| row[:price].value }).to eq([50])
    end
  end
end
