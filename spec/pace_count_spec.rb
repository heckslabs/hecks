require "spec_helper"
require "tmpdir"
require "json"
require "time"
require "hecks/hecks/adapters/pace_reading"

# A count of named events inside a window of the event tap: the figure a poll's firings an hour are
# measured by, before and after its driving event replaces it.
RSpec.describe Hecks::Adapters::PaceReading, "#count" do
  let(:aggregate) { boot_hecks_in_memory.registry.bluebook("Hecks").aggregate("Pace") }
  let(:dir)       { Dir.mktmpdir }
  let(:tap)       { File.join(dir, "events.jsonl") }

  after { FileUtils.rm_rf(dir) }

  def line(seq, event, age: 60)
    { kind: "event", at: (Time.now.utc - age).iso8601, aggregate: "Hecks::X", id: "i", event: event, seq: seq }
  end

  def write(lines) = File.write(tap, "#{lines.map(&:to_json).join("\n")}\n")

  def text(names, window = nil)
    described_class.new(aggregate: aggregate, tap: tap).count(run: "r", names: names, window: window)[:text]
  end

  it "counts each named event, noise included" do
    write([line(1, "AgentCheckRequested"), line(2, "AgentCheckRequested"), line(3, "WorkStarted")])
    expect(text("AgentCheckRequested WorkStarted")).to include("AgentCheckRequested: 2", "WorkStarted: 1")
  end

  it "reads zero for a name that did not happen and for a world with no tap" do
    expect(text("MessageSent")).to include("MessageSent: 0")
  end

  it "counts only the window asked" do
    write([line(1, "MessageSent", age: 600), line(2, "MessageSent", age: 10)])
    expect(text("MessageSent", "5m")).to include("MessageSent: 1", "window: 5m")
  end
end
