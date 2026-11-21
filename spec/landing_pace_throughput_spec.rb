require "spec_helper"
require_relative "support/landing_pace_scratch"
require "hecks/hecks/adapters/git"

# The Pace port's throughput: the branches landed in a window, and those whose commit origin has.
RSpec.describe Hecks::Adapters::LandingPaceReading do
  include LandingPaceScratch

  let(:rows) do
    [["BranchLanded", "Delivery::Landing", "run-1", "a", Time.now.utc.iso8601, "sha-a"],
     ["BranchLanded", "Delivery::Landing", "run-2", "b", Time.now.utc.iso8601, "sha-b"]]
  end

  def origin_has_sha_a
    git = instance_double(Hecks::Adapters::Git)
    allow(git).to receive(:ancestor?) { |sha, _ref| sha == "sha-a" }
    allow(Hecks::Adapters::Git).to receive(:new).and_return(git)
  end

  def throughput(hours: 24)
    allow(described_class::Ledger).to receive(:path).and_return(scratch_events(rows))
    origin_has_sha_a
    described_class.new.throughput(hours: hours)[:text]
  end

  it "counts what landed and what shipped" do
    expect(throughput).to include("landed: 2", "shipped: 1")
  end

  it "names the branch still waiting to ship" do
    expect(throughput).to include("waiting to ship: 1", "  b")
  end

  it "says there is no ledger when Landing is not kept in a SQLite file" do
    expect(described_class.new.throughput[:text]).to eq(described_class::NO_LEDGER)
  end
end
