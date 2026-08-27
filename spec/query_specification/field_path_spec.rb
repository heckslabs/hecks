require "spec_helper"

# S2 (docs/audits/2026-08-10-main-bug-audit.md) — `dig`/`read` used to try
# a symbol key, then `||` into the string spelling: `current[segment.to_sym]
# || current[segment]`. When the symbol key holds a genuinely-stored
# `false`, `false || current[segment]` falls through to the (usually
# absent) string spelling and returns `nil` instead of the real answer.
# The seal admits boolean leaves (`SCALAR_PRIMITIVES` below carries
# `TrueClass`/`FalseClass`), so a query filtering on a `false`-valued leaf
# silently never matched. This is the root helper every in-process query
# path (`Ports::Query::InMemory`, `Runtime::QueryInterpreter`) digs a
# record through, so fixing it here retires the bug everywhere it dug.
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

    # M5 (docs/audits/2026-08-10-main-bug-audit.md) — `.dig`/`.read`'s own
    # contract is "the held value, or nil — never a raise". Stepping a
    # dotted path onto an Array (a `list_of` attribute, or any other
    # Array a stored hash happens to hold) broke it: `Array#[]` demands
    # an Integer/Range index, so `current[segment]` (a String) raised a
    # raw `TypeError` straight through `dig` instead of answering nil.
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
      # THE ADVERSARIAL CASE: if the symbol side genuinely holds `false`,
      # nothing may fall through to the string side even when the string
      # side holds something else entirely — presence at the symbol key
      # decides the read outright.
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
