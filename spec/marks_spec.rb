require "spec_helper"

# Assembly::Marks has no direct coverage anywhere else — every other spec
# exercises it indirectly, through a full domain boot. `bindings` specifically:
# a saga's dispatch bindings ride the same self-describing spelling a
# where-clause's value does (QuerySpecification.render_value /
# IR.render_value), and had the same gap `where_clause` did until this —
# `read` recovers an object literal and a kwarg reference (the bug that broke
# banking's saga narrative once already) but not a number or boolean, because
# nothing in the real corpus has ever bound one literally.
RSpec.describe Hecksagain::Bluebook::Assembly::Marks do
  describe ".bindings" do
    it "recovers a kwarg reference as the Symbol it names" do
      expect(described_class.bindings(source: ":amount")).to eq(source: :amount)
    end

    it "recovers a literal number, not the text render_value wrote" do
      expect(described_class.bindings(retry_count: "3")).to eq(retry_count: 3)
      expect(described_class.bindings(rate: "1.5")).to eq(rate: 1.5)
    end

    it "recovers a literal boolean" do
      expect(described_class.bindings(active: "true")).to eq(active: true)
      expect(described_class.bindings(active: "false")).to eq(active: false)
    end

    it "recovers an object literal — the narrative binding that once broke a saga" do
      expect(described_class.bindings(narrative: '{:text=>"transfer out"}'))
        .to eq(narrative: { text: "transfer out" })
    end

    it "leaves a plain word as the string it is" do
      expect(described_class.bindings(label: "plain")).to eq(label: "plain")
    end
  end
end
