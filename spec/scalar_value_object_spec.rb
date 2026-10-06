require "spec_helper"

# Three halves of one rule, asserted together: the `value_object "Price", Integer` shorthand,
# the runtime `.value` alias for single-attribute value objects, and call-site scalar wrapping.
# The fixture is also a parser-parity corpus member.
RSpec.describe "single-element value objects strictly answer .value" do
  SCALAR_VO_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/scalar_value_objects.bluebook")

  def load_stickers
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
     InMemoryDomain::PRISM_ADAPTER, SCALAR_VO_BLUEBOOK].each { |file| Kernel.load(file) }
  end

  def boot_stickers
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_stickers
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def sticker_aggregate
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { load_stickers }
    registry.bluebook("ScalarValueObjects").aggregate("Sticker")
  end

  # A value object declared by hand, one `field: "Type"` pair per attribute.
  def declared_value_object(name, **fields)
    attributes = fields.map { |field, type| Hecks::Bluebook::Attribute.new(name: field, type: type) }
    Hecks::Bluebook::ValueObject.declare(name: name, attributes: attributes)
  end

  def build_aggregate_in_shim(name, &body)
    Hecks::Bluebook::DSL::ConstShim.with(->(const) { const }) do
      Hecks::Bluebook::DSL::AggregateBuilder.build(name, &body)
    end
  end

  def printed_sticker(ref, price)
    boot_stickers.dispatch_flat("ScalarValueObjects::Sticker.Print", ref: ref, price: price)
    ScalarValueObjects::Sticker.find(ref)
  end

  def runtime_with_two_stickers
    runtime = boot_stickers
    runtime.dispatch_flat("ScalarValueObjects::Sticker.Print", ref: "S5", price: 40)
    runtime.dispatch_flat("ScalarValueObjects::Sticker.Print", ref: "S6", price: 50)
    runtime
  end

  describe "the bare value_object shorthand" do
    it "declares exactly one attribute, named value, of the given type" do
      shape = sticker_aggregate.value_object("StickerRef")

      expect(shape.attributes.map { |a| [a.name, a.type.to_s, a.list?, a.optional?] })
        .to eq([[:value, "String", false, false]])
    end

    it "is byte-equivalent sugar for the block form's own attribute :value line" do
      shorthand = sticker_aggregate.value_object("Shelf").to_h
      spelled   = declared_value_object("Shelf", value: "Integer").to_h

      expect(shorthand).to eq(spelled)
    end

    it "refuses a type AND a block together — two answers to one question" do
      expect { build_aggregate_in_shim("Bad") { value_object("X", String) { attribute :y, Integer } } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /declares both a type .* and a block/)
    end

    it "keeps today's behavior for neither type nor block: an empty attribute list" do
      # Pinned deliberately, not endorsed: the shorthand must not change what this spelling builds.
      aggregate = build_aggregate_in_shim("Bare") { value_object "Empty" }

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

    it "answers the sole attribute whatever it is actually named", :aggregate_failures do
      price = value_of("Price", { amount: 7 })

      expect(price.value).to eq(7)
      expect(price.amount).to eq(7)
      expect(price.respond_to?(:value)).to be(true)
    end

    it "aliases indexed reads and key? the same way", :aggregate_failures do
      price = value_of("Price", { amount: 7 })

      expect(price[:value]).to eq(7)
      expect(price["value"]).to eq(7)
      expect(price.key?(:value)).to be(true)
    end

    it "writes through the alias into the REAL field — with(:value, x) never mints a :value key" do
      expect(value_of("Price", { amount: 7 }).with(:value, 9).to_h).to eq(amount: 9)
    end

    it "serializes under the real field name, not the alias", :aggregate_failures do
      expect(value_of("Price", { amount: 7 }).to_h).to eq(amount: 7)
      expect(value_of("Price", { amount: 7 }).to_json).to eq('{"amount":7}')
    end

    it "keeps the multi-attribute refusal: .value stays a NoMethodError", :aggregate_failures do
      pair = Hecks::Runtime::Value.build(declared_value_object("Pair", a: "String", b: "String"), { a: "x", b: "y" })

      expect { pair.value }.to raise_error(NoMethodError)
      expect(pair.respond_to?(:value)).to be(false)
      expect(pair[:value]).to be_nil
      expect(pair.key?(:value)).to be(false)
    end
  end

  describe "call-site scalar collapsing" do
    it "collapses a bare scalar into the sole field, real name and shorthand name alike", :aggregate_failures do
      sticker = printed_sticker("S1", 7)

      expect(sticker.ref.to_h).to eq(value: "S1")
      expect(sticker.price.to_h).to eq(amount: 7)
      expect(sticker.price.value).to eq(7)
    end

    it "keeps the explicit field-named spelling working unchanged" do
      runtime = boot_stickers
      runtime.dispatch_flat("ScalarValueObjects::Sticker.Print", ref: { value: "S2" }, price: { amount: 3 })

      expect(ScalarValueObjects::Sticker.find("S2").price.to_h).to eq(amount: 3)
    end

    it "collapses through a mutation too" do
      runtime = boot_stickers
      runtime.dispatch_flat("ScalarValueObjects::Sticker.Print", ref: "S3", price: 1)
      runtime.dispatch_flat("ScalarValueObjects::Sticker.Reprice", sticker: "S3", price: 12)

      expect(ScalarValueObjects::Sticker.find("S3").price.value).to eq(12)
    end

    it "still refuses a bare scalar for a genuinely multi-field value object" do
      boot_stickers.dispatch_flat("ScalarValueObjects::Sticker.Print", ref: "S4", price: 2)

      # The fixture has no multi-field argument, so the refusal is pinned at the coercion
      # directly, against an ad-hoc two-field shape: auto-wrap must stay count-gated.
      two_field = declared_value_object("Range", lo: "Integer", hi: "Integer")
      expect { Hecks::Runtime::Value.fields_for(two_field, :range, 5) }.to raise_error(Hecks::Runtime::TypeMismatch)
    end

    it "answers a bare-field query over a single-attribute value object's own field" do
      at_forty = runtime_with_two_stickers.query("ScalarValueObjects::Sticker.AtPrice", price: 40)

      expect(at_forty.map { |row| row[:ref].value }).to eq(["S5"])
    end

    it "answers a bare-field query over a single-field reference's own field" do
      by_ref = runtime_with_two_stickers.query("ScalarValueObjects::Sticker.ByRef", ref: "S6")

      expect(by_ref.map { |row| row[:price].value }).to eq([50])
    end
  end
end
