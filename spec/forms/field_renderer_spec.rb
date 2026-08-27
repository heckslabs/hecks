require "spec_helper"
require "hecks/forms/field_renderer"

# S2 (docs/audits/2026-08-10-main-bug-audit.md) — `.dig` read a flat
# key with `values[path.to_s] || values[path.to_sym]` and a nested step
# with `acc[segment.to_sym] || acc[segment]`, both of which drop a
# genuinely-stored `false` to `nil` (`false || …` falls through). A
# sticky re-render of a refused boolean-field command, or a prefill from
# a record actually holding `false`, used to render as though the field
# had never been filled in at all.
RSpec.describe Hecks::Forms::FieldRenderer do
  describe ".dig" do
    it "reads a flat, string-keyed stored false rather than nil" do
      expect(described_class.dig({ "active" => false }, "active")).to be(false)
    end

    it "reads a flat, symbol-keyed stored false rather than nil" do
      expect(described_class.dig({ active: false }, "active")).to be(false)
    end

    it "reads a nested stored false rather than nil" do
      expect(described_class.dig({ flag: { active: false } }, "flag.active")).to be(false)
    end

    it "still reads a stored true, flat or nested" do
      expect(described_class.dig({ "active" => true }, "active")).to be(true)
      expect(described_class.dig({ flag: { active: true } }, "flag.active")).to be(true)
    end

    it "still prefers the flat dotted key over a nested walk when both would answer" do
      expect(described_class.dig({ "amount.cents" => "1050", amount: { cents: 999 } }, "amount.cents"))
        .to eq("1050")
    end

    it "still reads a genuinely absent key as nil" do
      expect(described_class.dig({}, "missing")).to be_nil
      expect(described_class.dig({ flag: {} }, "flag.active")).to be_nil
    end
  end
end
