require "spec_helper"
require "hecks/forms/params"

# The Rust web host's own `nest()` (rust/host/src/web.rs) mirrors this
# method exactly, and carried the identical path-prefix collision bug: a
# flat, dotted payload where one field is a plain scalar ("price") and
# another implies it should be a nested group ("price.cents") used to
# either crash with a raw `TypeError` or silently clobber a whole nested
# hash down to a lone scalar, depending only on which pair the input
# hash happened to iterate first.
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

    it "never silently clobbers the nested hash with the scalar (dotted-then-scalar order)" do
      # Before the fix, this order raised nothing at all — `result[:price]`
      # was quietly overwritten with the scalar "10", losing `cents`
      # entirely with no error to show for it.
      pairs = { "price.cents" => "1050", "price" => "10" }
      expect { described_class.nest(pairs) }.to raise_error(ArgumentError)
    end

    it "never raises a raw TypeError from indexing into a scalar with a symbol (scalar-then-dotted order)" do
      # Before the fix, this order blew up with `TypeError: no implicit
      # conversion of Symbol into Integer` — a confusing internal error
      # for what is really a malformed/conflicting submission.
      pairs = { "price" => "10", "price.cents" => "1050" }
      error = nil
      begin
        described_class.nest(pairs)
      rescue StandardError => e
        error = e
      end
      expect(error).to be_a(ArgumentError)
    end

    it "catches the collision at a deeper level too, not just the top segment" do
      pairs = { "a.b" => "scalar", "a.b.c" => "deep" }
      expect { described_class.nest(pairs) }.to raise_error(ArgumentError)
    end
  end
end
