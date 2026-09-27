require "spec_helper"

# Pins S2 (docs/audits/2026-08-10-main-bug-audit.md): a stored `false` leaf must read back
# as `false`, not fall through a `sym || string` lookup to nil.
RSpec.describe Hecks::QuerySpecification::FieldPath do
  describe ".dig" do
    it "reads a stored false leaf, symbol-keyed, rather than nil" do
      expect(described_class.dig({ active: false }, "active")).to be(false)
    end

    it "reads a stored false leaf, string-keyed, rather than nil" do
      expect(described_class.dig({ "active" => false }, "active")).to be(false)
    end

    it "reads a stored false leaf through a dotted, nested path — either key spelling" do
      expect(described_class.dig({ flags: { active: false } }, "flags.active")).to be(false)
      expect(described_class.dig({ "flags" => { "active" => false } }, "flags.active")).to be(false)
    end

    it "still reads a stored true leaf" do
      expect(described_class.dig({ active: true }, "active")).to be(true)
      expect(described_class.dig({ flags: { active: true } }, "flags.active")).to be(true)
    end

    it "still reads a genuinely absent key as nil, not the other key's spelling" do
      expect(described_class.dig({ other: true }, "active")).to be_nil
      expect(described_class.dig({ flags: { other: true } }, "flags.active")).to be_nil
    end

    # M5 (docs/audits/2026-08-10-main-bug-audit.md): `.dig` answers nil, never raises,
    # when a dotted path steps onto an Array (`Array#[]` rejects a String index).
    it "reads nil rather than raising when a dotted path steps onto an Array" do
      expect { described_class.dig({ items: [1, 2, 3] }, "items.name") }.not_to raise_error
      expect(described_class.dig({ items: [1, 2, 3] }, "items.name")).to be_nil
    end

    it "reads nil rather than raising when the Array is nested deeper in the path" do
      expect(described_class.dig({ board: { items: %w[a b] } }, "board.items.name")).to be_nil
    end
  end

  describe ".read" do
    it "prefers the symbol spelling when both a true string value and a false symbol value are held" do
      # If the symbol side holds `false`, the string side must never be consulted.
      expect(described_class.read({ active: false, "active" => true }, "active")).to be(false)
    end

    it "falls through to the string spelling only when the symbol key is truly absent" do
      expect(described_class.read({ "active" => false }, "active")).to be(false)
    end

    it "reads nil for an Array holder rather than raising TypeError" do
      expect(described_class.read([1, 2, 3], "name")).to be_nil
    end
  end
end
