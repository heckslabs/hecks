require "spec_helper"
require_relative "../../rust/project/naming"
require_relative "../../rust/project/bridging"

# `attribute :refunded_amount, Money, default: { cents: 0 }` — Money's
# own `currency` attribute carries its OWN `default: "USD"`, so the
# literal hash names only `cents`, relying on Money's per-field default
# for the rest. No domain in the corpus banking/pizzas/compliance
# examples declared this shape (confirmed: every Hash-typed attribute
# default in those three either names every field explicitly or has
# none at all), so this bug was latent — real, but unexercised by
# anything codegen_parity_spec.rb's own corpus-based proof already
# covers. Found live generating lifeadelics' vendored
# embryonaut_bluebooks/payments — the first domain in the corpus to
# hit it. Tested directly here instead of via a new fixture domain,
# same reasoning constraints_spec.rb's own header already gives for
# the identical shape of latent bug.
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
