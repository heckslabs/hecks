require "spec_helper"
require "tmpdir"
require "json"
require "time"
require "hecks/hecks/adapters/pace_reading"

# A reading of the event tap: gross events an hour with the bluebook's noise left out, finished
# items an hour, and the finished per 1,000 events.
RSpec.describe Hecks::Adapters::PaceReading do
  let(:registry)  { boot_hecks_in_memory.registry }
  let(:aggregate) { registry.bluebook("Hecks").aggregate("Pace") }
  let(:dir)       { Dir.mktmpdir }
  let(:tap)       { File.join(dir, "events.jsonl") }

  after { FileUtils.rm_rf(dir) }

  def line(seq, event, age: 60)
    { kind: "event", at: (Time.now.utc - age).iso8601, aggregate: "Hecks::X", id: "i", event: event, seq: seq }
  end

  def write(lines) = File.write(tap, "#{lines.map(&:to_json).join("\n")}\n")

  def text(window = nil)
    described_class.new(aggregate: aggregate, tap: tap).read(run: "r", window: window)[:text]
  end

  it "reads zero for a window with no events" do
    write([])
    expect(text).to include("gross: 0", "net: 0", "efficiency: 0")
  end

  it "reads zero where no tap file is kept" do
    expect(text).to include("gross: 0")
  end

  it "leaves the bluebook's noise out of gross" do
    write([line(1, "WorkStarted"), line(2, "JobRead"), line(3, "RunRead")])
    expect(text).to include("gross: 1/h")
  end

  it "counts finished items and the finished per 1,000 events" do
    write([line(1, "WorkFinished")] + (2..4).map { |seq| line(seq, "WorkStarted") })
    expect(text).to include("net: 1/h", "efficiency: 250.0")
  end

  it "reads only the window asked" do
    write([line(1, "WorkStarted", age: 600), line(2, "WorkStarted", age: 10)])
    expect(text("5m")).to include("events: 1", "window: 5m")
  end

  it "reads the noise from the bluebook" do
    expect(aggregate.value_objects.find { |o| o.hecks_name == "Noise" }.members.map { |m| m.to_h[:event] }).to include("JobRead")
  end
end
