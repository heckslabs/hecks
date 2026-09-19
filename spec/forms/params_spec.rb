require "spec_helper"
require "hecks/forms/params"

# The Rust web host's own `nest()` (rust/host/src/web.rs) mirrors this
# method exactly, and shares the identical path-prefix collision case: a
# flat, dotted payload where one field is a plain scalar ("price") and
# another implies it should be a nested group ("price.cents") raises
# `ArgumentError` by name, rather than crashing with a raw `TypeError` or
# silently clobbering a whole nested hash down to a lone scalar,
# regardless of which pair the input hash happens to iterate first.
RSpec.describe Hecks::Forms::Params do
  describe ".nest" do
    it "nests ordinary dotted pairs into their tree shape" do
      pairs = { "amount.cents" => 1050, "amount.currency" => "USD", "note" => "hi" }
      expect(described_class.nest(pairs)).to eq(amount: { cents: 1050, currency: "USD" }, note: "hi")
    end

    it "leaves unrelated sibling fields untouched alongside a deeper nest" do
      pairs = { "name.given" => "Ada", "name.family" => "Lovelace", "email.address" => "ada@example.com" }
      expect(described_class.nest(pairs)).to eq(
        name:  { given: "Ada", family: "Lovelace" },
        email: { address: "ada@example.com" }
      )
    end

    it "raises a clean ArgumentError when a scalar is planted before its own dotted child" do
      pairs = { "price" => "10", "price.cents" => "1050" }
      expect { described_class.nest(pairs) }.to raise_error(ArgumentError, /price/)
    end

    it "raises a clean ArgumentError when a scalar is planted after its own dotted child" do
      pairs = { "price.cents" => "1050", "price" => "10" }
      expect { described_class.nest(pairs) }.to raise_error(ArgumentError, /price/)
    end

    it "catches the collision at a deeper level too, not just the top segment" do
      pairs = { "a.b" => "scalar", "a.b.c" => "deep" }
      expect { described_class.nest(pairs) }.to raise_error(ArgumentError)
    end
  end
end
