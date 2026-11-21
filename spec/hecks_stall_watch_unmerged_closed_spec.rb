require "spec_helper"
require "time"
require "hecks/hecks/adapters/stall_watching"

# A closed boarding leaves no train-unmerged line: the row closes on `BoardingClosed`.
RSpec.describe Hecks::Adapters::StallWatching::Openings do
  let(:kind) do
    { kind: "train-unmerged", aggregate: "Hecks::SendTrain", opens: "BoardingQueued",
      closes: "BranchPushed,BoardingClosed", minutes: 45, forgets: 1440 }
  end

  def line(event, at)
    { "kind" => "event", "aggregate" => "Hecks::SendTrain", "id" => "b1", "event" => event, "at" => at, "links" => {} }
  end

  it "leaves no line for a boarding that closed" do
    tap = [line("BoardingQueued", "2026-11-21T01:00:00Z"), line("BoardingClosed", "2026-11-21T09:00:00Z")]

    expect(described_class.new(kind, tap).unclosed).to be_empty
  end

  it "lists a queued boarding that has not closed" do
    expect(described_class.new(kind, [line("BoardingQueued", "2026-11-21T01:00:00Z")]).unclosed.keys).to eq(["b1"])
  end
end
