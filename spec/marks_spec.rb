require "spec_helper"

# Marks has no other direct coverage. `bindings` reads the Hecks::Literal spelling that
# every to_h-bound literal field shares.
RSpec.describe Hecks::Bluebook::Assembly::Marks do
  describe ".bindings" do
    it "recovers a kwarg reference as the Symbol it names" do
      expect(described_class.bindings(source: ":amount")).to eq(source: :amount)
    end

    it "recovers a literal number, not the text Literal.render wrote" do
      expect(described_class.bindings(retry_count: "3")).to eq(retry_count: 3)
      expect(described_class.bindings(rate: "1.5")).to eq(rate: 1.5)
    end

    it "recovers a literal boolean" do
      expect(described_class.bindings(active: "true")).to eq(active: true)
      expect(described_class.bindings(active: "false")).to eq(active: false)
    end

    it "recovers an object literal — the narrative binding that once broke a saga" do
      expect(described_class.bindings(narrative: '{text: "transfer out"}'))
        .to eq(narrative: { text: "transfer out" })
    end

    # Literal.render is the only writer of this wire spelling, so it builds the fixture.
    it "recovers an object literal whose own field embeds a quote" do
      wire = Hecks::Literal.render(text: 'a "quoted" word')

      expect(described_class.bindings(narrative: wire)).to eq(narrative: { text: 'a "quoted" word' })
    end

    it "leaves a plain word as the string it is" do
      expect(described_class.bindings(label: "plain")).to eq(label: "plain")
    end
  end
end
