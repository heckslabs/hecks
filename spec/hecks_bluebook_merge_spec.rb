require "spec_helper"
require "hecks/hecks/landing/bluebook_merge"

# Two edits of one bluebook merge by declaration: different declarations are both kept, and one
# declaration changed differently on both sides is refused by its name.
RSpec.describe Hecks::Landing::BluebookMerge do
  let(:base) do
    "Hecks.bluebook \"S\" do\n  domain_module \"S\" do\n    aggregate \"A\" do\n      attribute :x, String\n    end\n  end\nend\n"
  end

  def adding(name)
    base.sub("    end\n  end", "    end\n\n    aggregate \"#{name}\" do\n      attribute :y, String\n    end\n  end")
  end

  it "keeps the aggregates each side added at the same spot", :aggregate_failures do
    merged = described_class.new(base, adding("B"), adding("C")).merged
    expect(merged).to include("aggregate \"B\"", "aggregate \"C\"", "aggregate \"A\"")
    expect { RubyVM::InstructionSequence.compile(merged) }.not_to raise_error
  end

  it "refuses one declaration changed on both sides, by its name" do
    merge = described_class.new(base, base.sub(":x", ":mine"), base.sub(":x", ":theirs"))
    expect { merge.merged }.to raise_error(described_class::Refused, "aggregate A changed on both sides")
  end

  it "takes a change only one side made" do
    expect(described_class.new(base, base, base.sub(":x", ":z")).merged).to eq(base.sub(":x", ":z"))
  end

  it "refuses a merge whose text does not compile" do
    merge = described_class.new(base, base, base.sub("      attribute :x, String\n", "      attribute :x, (\n"))
    expect { merge.merged }.to raise_error(described_class::Refused, /does not compile/)
  end
end
