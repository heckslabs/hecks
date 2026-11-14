require "spec_helper"
require "hecks/hecks/adapters/landed_branches"

# The branches `Landing` recorded as landed, read from a registry. The aggregate is looked up in the
# delivery package the Hecks domain attaches; the rows are canned, so no journal is read.
RSpec.describe Hecks::Adapters::LandedBranches do
  let(:bluebook) { Hecks.describe(File.expand_path("../lib/hecks/hecks", __dir__)).registry.bluebooks["Delivery"] }
  let(:rows) { [] }
  let(:repository) { Struct.new(:all).new(rows) }
  let(:registry) { instance_double(Hecks::Runtime::Registry, bluebook: bluebook, repository: repository) }
  let(:named) { Struct.new(:value) }

  def row(status, branch) = { status: named.new(status), branch: named.new(branch) }

  it "finds the Landing aggregate in the delivery bluebook" do
    expect(described_class.landing_aggregate(registry).hecks_name).to eq("Landing")
  end

  it "reads nothing without a registry" do
    expect(described_class.of(nil)).to eq([])
  end

  context "with rows" do
    let(:rows) do
      [row("landed", "work/a"), row("refused", "work/b"), row("landed", "work/a"), row("retired", "work/c"),
       row("landed", ""), row("landed", "work/d")]
    end

    it "answers each landed branch once, and no other", :aggregate_failures do
      expect(described_class.of(registry)).to eq(%w[work/a work/d])
    end
  end
end
