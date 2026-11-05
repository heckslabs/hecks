# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_journal"

# The board's reader of the runtime's event log: a delivery line is attached to the event it
# answered, so the page can draw event, policy, command and what followed as one chain.
RSpec.describe Hecks::Adapters::PipelineJournal do
  let(:dir) { Dir.mktmpdir("tap-reader") }
  let(:log) { File.join(dir, "events.jsonl") }

  after { FileUtils.rm_rf(dir) }

  def line(**fields) = "#{JSON.generate(fields)}\n"

  def write(*lines) = File.write(log, lines.join)

  def board
    described_class.new(settings: { trace: ->(*) { { events: [] } }, tap: log, ttl: 0 })
  end

  def send_train_log
    write(line(kind: "event", at: "2026-11-02T10:00:00Z", aggregate: "Hecks::SendTrain", id: "r1", event: "BoardRequested"),
          line(kind: "reaction", at: "2026-11-02T10:00:01Z", id: "r1", event: "BoardRequested", policy: "CarryWhenBoarded",
               command: "Hecks::SendTrain.Carry", outcome: "delivered"),
          line(kind: "event", at: "2026-11-02T10:00:02Z", aggregate: "Hecks::SendTrain", id: "r1", event: "TrainAnswered"))
  end

  it "shows a Memory-bound domain's event, which no store holds" do
    send_train_log
    expect(board.recent.map { |row| row[:aggregate] }.uniq).to eq(["Hecks::SendTrain"])
  end

  it "passes the link keys and the saga correlation of an event through to its row", :aggregate_failures do
    write(line(kind: "event", at: "2026-11-02T10:00:00Z", aggregate: "Hecks::Landing", id: "l1", event: "BranchLanded",
               links: { landed: "a1b2c3d" }, correlation: { "landed.value" => "a1b2c3d" }))
    row = board.recent.find { |found| found[:name] == "BranchLanded" }
    expect(row).to include(links: { "landed" => "a1b2c3d" }, correlation: { "landed.value" => "a1b2c3d" })
  end

  it "attaches the policy delivery to the event it answered", :aggregate_failures do
    send_train_log
    row = board.recent.find { |found| found[:name] == "BoardRequested" }
    expect(row[:reactions].first).to include(policy: "CarryWhenBoarded", command: "Hecks::SendTrain.Carry", outcome: "delivered")
  end

  it "names the events that followed on the same record" do
    send_train_log
    row = board.recent.find { |found| found[:name] == "BoardRequested" }
    expect(row[:reactions].first[:emitted]).to eq(["TrainAnswered"])
  end

  it "skips a line that is not JSON" do
    write("not json\n", line(kind: "event", at: "2026-11-02T10:00:00Z", aggregate: "A", id: "1", event: "E"))
    expect(board.recent.size).to eq(1)
  end
end
