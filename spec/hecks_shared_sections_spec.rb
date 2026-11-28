require "spec_helper"
require "hecks/hecks/adapters/shared_sections"

# Two work items share a bluebook when both name it by sections and none is common to both; the
# helper names the file and the other's sections, and says nothing of a real overlap or of none.
RSpec.describe Hecks::Adapters::SharedSections do
  it "names the file two work items share and the sections the other holds" do
    shared = described_class.between(["lib/x/x.bluebook#Coder"], ["lib/x/x.bluebook#Brief,Turn"])
    expect(shared.map(&:to_a)).to eq([["lib/x/x.bluebook", %w[Brief Turn]]])
  end

  it "meets one file however its path is spelled" do
    expect(described_class.between(["./lib/x/x.bluebook#Coder"], ["lib/x/../x/x.bluebook#Brief"]).size).to eq(1)
  end

  it "says nothing of a common section, which is an overlap and not a share" do
    expect(described_class.between(["lib/x/x.bluebook#Coder"], ["lib/x/x.bluebook#Coder,Brief"])).to eq([])
  end

  it "says nothing of a whole-file claim or of another file" do
    mine = ["lib/x/x.bluebook", "lib/y.bluebook#A"]
    expect(described_class.between(mine, ["lib/x/x.bluebook#B", "lib/z.bluebook#B"])).to eq([])
  end

  it "words the notice a coordination line ends with" do
    expect(described_class.notice(["s.bluebook#C"], ["s.bluebook#B"]))
      .to eq("; shares s.bluebook with you: it holds B, edit only your own sections of it")
  end
end
