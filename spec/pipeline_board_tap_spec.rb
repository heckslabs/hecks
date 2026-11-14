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

  def numbered(count)
    Array.new(count) { |n| line(kind: "event", at: format("t%04d", n), aggregate: "A", id: n.to_s, event: "E") }
  end

  # The keys of the newest events before and after one more line is appended to a log that
  # already holds more lines than the reader keeps.
  def keys_around_an_append
    write(*numbered(700))
    reader = board
    before = reader.recent(5).map { |row| row[:key] }
    File.write(log, line(kind: "event", at: "t9999", aggregate: "A", id: "new", event: "E"), mode: "a")
    [before, reader.recent(6).map { |row| row[:key] }]
  end

  it "keeps the key of every earlier event when a line is appended, so a stream sends only the new one" do
    before, after = keys_around_an_append
    expect(after - before).to eq(["tap:t9999:A:new:E:0"])
  end

  it "tells apart two events alike in every field" do
    twin = line(kind: "event", at: "2026-11-02T10:00:00Z", aggregate: "A", id: "1", event: "E")
    write(twin, twin)
    expect(board.recent.map { |row| row[:key] }).to contain_exactly(end_with(":E:0"), end_with(":E:1"))
  end
end
