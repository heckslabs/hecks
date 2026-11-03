require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/red_flag_marker"
require "hecks/hecks/adapters/red_flag_guard"
require "hecks/hecks/adapters/red_flag_report"

# The red flag of a repository is one file in its git directory: one flag at a time, a second red
# run recorded on it, check-ins listed, and a green run lowering it. Every example uses its own
# directory.
RSpec.describe Hecks::Adapters::RedFlagMarker do
  let(:dir) { Dir.mktmpdir("hecks-red-flag-spec") }
  let(:marker) { described_class.new(dir, clock: -> { Time.utc(2026, 11, 2, 12, 0, 0) }) }
  let(:run) { { ci_run: "99", jobs: "rspec, fuzz", rows: "red-a" } }

  after { FileUtils.remove_entry(dir) }

  it "raises a flag for a red run" do
    expect(marker.raise!(commit: "abcdef1234567", run: run).first).to eq(:raised)
  end

  it "names the flag for the commit" do
    expect(marker.raise!(commit: "abcdef1234567", run: run).last["id"]).to eq("flag-abcdef1234")
  end

  it "records a second red run on the standing flag, not a new flag", :aggregate_failures do
    marker.raise!(commit: "aaaaaaaaaaaa", run: run)
    state, flag = marker.raise!(commit: "bbbbbbbbbbbb", run: run.merge(ci_run: "100"))

    expect(state).to eq(:noted)
    expect(flag["runs"].size).to eq(2)
  end

  it "changes nothing when the same run is reported again", :aggregate_failures do
    marker.raise!(commit: "aaaaaaaaaaaa", run: run)
    state, flag = marker.raise!(commit: "aaaaaaaaaaaa", run: run)

    expect(state).to eq(:unchanged)
    expect(flag["runs"].size).to eq(1)
  end

  it "keeps the last green head of main for a kick" do
    marker.raise!(commit: "aaaaaaaaaaaa", run: run.merge(last_green: "0b49c62c2c"))

    expect(marker.read["last_green"]).to eq("0b49c62c2c")
  end

  it "records the kick: the branch, the commits reverted and the row filed", :aggregate_failures do
    marker.raise!(commit: "aaaaaaaaaaaa", run: run)
    flag = marker.kicked!(branch: "red-main-flag-aaaaaaaaaa", reverted: %w[a2 a1], row: "red-flag-aaaaaaaaaa")

    expect(flag["kicked"]).to include("branch" => "red-main-flag-aaaaaaaaaa", "reverted" => %w[a2 a1])
    expect(marker.kicked!(branch: "x", reverted: [], row: "y")).to include("kicked")
  end

  it "lists who checked in and what they take", :aggregate_failures do
    marker.raise!(commit: "aaaaaaaaaaaa", run: run)
    flag = marker.check_in!(session: "s1", taking: "red-a")

    expect(flag["checkins"].first).to include("session" => "s1", "taking" => "red-a")
  end

  it "has nobody to check in to without a flag" do
    expect(marker.check_in!(session: "s1", taking: "red-a")).to be_nil
  end

  it "lowers the flag on a green run", :aggregate_failures do
    marker.raise!(commit: "aaaaaaaaaaaa", run: run)

    expect(marker.clear!["id"]).to eq("flag-aaaaaaaaaa")
    expect(marker.read).to be_nil
  end

  it "says the red time, the failed jobs and the helpers", :aggregate_failures do
    marker.raise!(commit: "aaaaaaaaaaaa", run: run)
    marker.check_in!(session: "s1", taking: "red-a")
    text = Hecks::Adapters::RedFlagReport.new(marker.read, now: Time.utc(2026, 11, 2, 12, 30, 0)).text

    expect(text).to include("red for 30 min", "failing jobs: rspec, fuzz", "helping: s1 takes red-a")
  end
end
