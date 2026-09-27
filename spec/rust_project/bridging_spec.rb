require "spec_helper"
require_relative "../../rust/project/naming"
require_relative "../../rust/project/bridging"

# `attribute :refunded_amount, Money, default: { cents: 0 }` — Money's own
# `currency` attribute carries its own `default: "USD"`, relied on for any
# field a literal default hash omits. Untested by the corpus-based proof in
# codegen_parity_spec.rb, since no banking/pizzas/compliance domain
# declares this shape.
RSpec.describe RustProjection::Projector do
  MONEY_VO = {
    name:       "Money",
    closed_set: false,
    attributes: [
      { name: "cents",    type: "Integer", default: nil },
      { name: "currency", type: "String",  default: "USD" }
    ]
  }.freeze

  VALUE_OBJECTS_BY_NAME = { "Money" => MONEY_VO }.freeze

  describe ".creation_default_rhs" do
    it "backfills a field the literal default omits from its VO's own per-field default" do
      attr = { name: "refunded_amount", type: "Money", default: { "cents" => 0 } }

      generated = described_class.creation_default_rhs(attr, VALUE_OBJECTS_BY_NAME)

      expect(generated).to eq('Money { cents: 0, currency: "USD".to_string() }')
    end

    it "keeps an explicitly-named field over the VO's own default" do
      attr = { name: "amount", type: "Money", default: { "cents" => 500, "currency" => "EUR" } }

      generated = described_class.creation_default_rhs(attr, VALUE_OBJECTS_BY_NAME)

      expect(generated).to eq('Money { cents: 500, currency: "EUR".to_string() }')
    end

    it "still raises the real, unrecoverable-gap error when a field has neither an explicit value nor a VO default" do
      no_default_money = {
        name: "Money", closed_set: false,
        attributes: [
          { name: "cents",    type: "Integer", default: nil },
          { name: "currency", type: "String",  default: nil }
        ]
      }
      attr = { name: "refunded_amount", type: "Money", default: { "cents" => 0 } }

      expect { described_class.creation_default_rhs(attr, { "Money" => no_default_money }) }
        .to raise_error(/missing field currency for Money/)
    end
  end

  describe ".complete_hash_default" do
    it "leaves an already-complete hash untouched, key-for-key" do
      completed = described_class.complete_hash_default({ "cents" => 100, "currency" => "GBP" }, "Money", VALUE_OBJECTS_BY_NAME)

      expect(completed).to eq(cents: 100, currency: "GBP")
    end

    it "passes a hash through unchanged for an unknown target type" do
      completed = described_class.complete_hash_default({ "cents" => 100 }, "Nonexistent", VALUE_OBJECTS_BY_NAME)

      expect(completed).to eq("cents" => 100)
    end
  end
end
