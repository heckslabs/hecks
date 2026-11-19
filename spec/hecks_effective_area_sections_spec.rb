require "spec_helper"
require "hecks/hecks/adapters/area_overlap"
require "hecks/hecks/adapters/dispatching/effective_area"

# A branch with commits keeps the sections its plan named, so a commit does not widen its claim.
RSpec.describe Hecks::Adapters::Dispatching::EffectiveArea do
  describe ".choose" do
    it "keeps a changed bluebook the plan named by sections as those sections" do
      held = described_class.choose(["lib/x/x.bluebook#Coder", "lib/x"], ["lib/x/x.bluebook", "lib/b.rb"])
      expect(held).to eq(["lib/x/x.bluebook#Coder", "lib/b.rb"])
    end

    it "does not clash with a different-section branch after a commit" do
      held = described_class.choose(["lib/x/x.bluebook#Coder"], ["lib/x/x.bluebook"])
      expect(Hecks::Adapters::AreaOverlap.first_overlap(held, ["lib/x/x.bluebook#Brief"])).to be_nil
    end
  end

  describe ".file?" do
    it "counts a sectioned word as naming one file" do
      expect(described_class.file?("lib/x/x.bluebook#A,B")).to be(true)
    end
  end
end
