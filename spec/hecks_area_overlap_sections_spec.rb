require "spec_helper"
require "hecks/hecks/adapters/area_overlap"

# Two Work items may hold one bluebook when they name different declarations of it
# (`x.bluebook#A`); a word with no sections still claims the whole file, so nothing real is missed.
RSpec.describe Hecks::Adapters::AreaOverlap do
  describe ".overlap? with section areas" do
    it "keeps different sections of one bluebook apart" do
      expect(described_class.overlap?("lib/x/x.bluebook#Coder", "lib/x/x.bluebook#Brief")).to be(false)
    end

    it "counts a shared section as an overlap" do
      expect(described_class.overlap?("lib/x/x.bluebook#Coder", "lib/x/x.bluebook#Brief, Coder")).to be(true)
    end

    it "counts the whole file as overlapping any section of it" do
      expect(described_class.overlap?("lib/x/x.bluebook", "lib/x/x.bluebook#Coder")).to be(true)
    end

    it "counts a directory as holding a section of a file beneath it" do
      expect(described_class.overlap?("lib/x", "lib/x/x.bluebook#Coder")).to be(true)
    end

    it "counts a changed file as touching a section claim when it is that file" do
      expect(described_class.overlap?("lib/x/x.bluebook#Coder", "lib/x/x.bluebook", file: true)).to be(true)
    end

    it "keeps a section of one file apart from another file" do
      expect(described_class.overlap?("lib/x/x.bluebook#Coder", "lib/y/y.bluebook")).to be(false)
    end
  end

  describe ".first_overlap with section areas" do
    it "finds the overlapping pair in a mix of sectioned and bare words" do
      mine = ["lib/x/x.bluebook#Coder", "lib/a.rb"]
      expect(described_class.first_overlap(mine, ["lib/x/x.bluebook#Brief", "lib/a.rb"])).to eq(["lib/a.rb", "lib/a.rb"])
    end
  end
end
