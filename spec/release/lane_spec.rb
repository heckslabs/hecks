require "spec_helper"
require "hecks/release/lane"

# The lane a work item's branch lands onto is read from the `Lane` rows, so no adapter names it.
RSpec.describe Hecks::Release::Lane do
  describe ".lands_here" do
    it "is the lane whose row says it lands here" do
      expect(described_class.lands_here).to eq("main")
    end

    it "refuses when no row says it lands here" do
      rows = [{ "name" => "main", "lands_here" => "no" }, { "name" => "stable", "lands_here" => "" }]
      allow(Hecks::Vocabulary).to receive(:rows).with("Lane").and_return(rows)

      expect { described_class.lands_here }.to raise_error(KeyError, /no Lane row says it lands here/)
    end
  end
end
