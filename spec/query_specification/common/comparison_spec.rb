require "spec_helper"

# M1, M2, M4 (docs/audits/2026-08-10-main-bug-audit.md) — all three were
# reported against `Ports::Query::InMemory`'s OWN, separate comparator
# copy, before it and `Runtime::QueryInterpreter`'s copy were unified into
# this one shared module (see this file's own header comment). Re-verified
# here against the CURRENT, shared implementation: all three are already
# fixed by that unification and this file exists to pin the fix down with
# a real regression test, not to re-fix anything.
RSpec.describe Hecks::QuerySpecification::Common::Comparison do
  describe "M1 — ne and a nil-held row" do
    it "does NOT match ne against a nil-held field, matching SQL's <> excluding NULL" do
      expect(described_class.holds?(:ne, nil, "active")).to be(false)
    end

    it "still matches ne between two real, unequal values" do
      expect(described_class.holds?(:ne, "closed", "active")).to be(true)
    end

    it "ne nil against nil is false, matching SQL's NULL <> NULL reading as unknown" do
      expect(described_class.holds?(:ne, nil, nil)).to be(false)
    end
  end

  describe "M2 — in, a nil-held row, and cross-type matching" do
    it "does NOT match in when the held value is nil, even if the candidate list holds an empty string" do
      expect(described_class.holds?(:in, nil, ["", "b"])).to be(false)
    end

    it "still matches in for a real, held candidate" do
      expect(described_class.holds?(:in, "b", ["a", "b"])).to be(true)
    end
  end

  describe "M4 — a multi-numeric value object unwraps identically for gt/lt on both sides" do
    it "leaves an AMBIGUOUS multi-numeric hash unchanged rather than picking the first member" do
      value = { width: 3, height: 4 }
      expect(described_class.comparable(value)).to eq(value)
    end

    it "unwraps an UNAMBIGUOUS single-numeric hash to its scalar" do
      expect(described_class.comparable({ cents: 500 })).to eq(500)
    end

    it "an ambiguous multi-numeric value object compares as false (never a number) for gt/lt, the same on every path" do
      value = { width: 3, height: 4 }
      expect(described_class.holds?(:gt, described_class.comparable(value), 1)).to be(false)
    end
  end
end
