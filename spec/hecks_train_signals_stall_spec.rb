require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Tap lines of one boarding, and the keys a look filed, for the train-signal groups.
module TrainSignalLooks
  RUN = "b0a4d1c2-0000-4000-8000-00000000c3d4".freeze

  def write_boarding(rows)
    lines = rows.each_with_index.map { |(event, ago), seq| line(seq + 1, event, RUN, ago).merge(aggregate: "Hecks::SendTrain") }
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def filed_keys
    aggregate = registry.bluebook("Hecks").aggregate("Stall")
    registry.repository("Hecks", aggregate).all.map { |record| Hecks::Adapters::StartedWork.value(record, :stall).to_s }
  end
end

# A faulted boarding and one whose checks failed are stalls at once; a queued boarding is one
# after forty-five minutes; a push that merged closes each.
RSpec.describe "StallWatch train signals" do
  include_context "with a stall watch tap"
  include TrainSignalLooks

  {
    "train-faulted"       => [[["PushFaulted", 1]], [["PushFaulted", 2], ["BranchPushed", 1]]],
    "train-checks-failed" => [[["TrainChecksFailed", 1]], [["TrainChecksFailed", 2], ["BranchPushed", 1]]],
    "train-unmerged"      => [[["BoardingQueued", 50]], [["BoardingQueued", 50], ["BranchPushed", 5]]]
  }.each do |kind, (open_rows, closed_rows)|
    it "files #{kind} for a line left open" do
      write_boarding(open_rows)
      detect("look-1")

      expect(filed_keys).to eq(["stall-#{kind}-#{TrainSignalLooks::RUN}"])
    end

    it "files nothing for #{kind} once the push merged" do
      write_boarding(closed_rows)
      detect("look-1")

      expect(filed_keys).to eq([])
    end
  end

  it "files nothing for a boarding queued 10 minutes ago" do
    write_boarding([["BoardingQueued", 10]])
    detect("look-1")

    expect(filed_keys).to eq([])
  end

  it "files nothing for a queued boarding whose pull request closed unmerged", :aggregate_failures do
    write_boarding([["BoardingQueued", 50], ["BoardingClosed", 49]])
    detect("look-1")

    expect(filed_keys).to eq([])
  end

  it "files nothing for a red boarding whose pull request then closed unmerged" do
    write_boarding([["TrainChecksFailed", 5], ["BoardingClosed", 1]])
    detect("look-1")

    expect(filed_keys).to eq([])
  end

  it "files nothing for a queued boarding whose checks failed" do
    write_boarding([["BoardingQueued", 50], ["TrainChecksFailed", 49]])
    detect("look-1")

    expect(filed_keys).not_to include("stall-train-unmerged-#{TrainSignalLooks::RUN}")
  end
end
