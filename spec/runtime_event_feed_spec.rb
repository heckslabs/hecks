# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/runtime/event_feed"

# The feed reads the tap's lines past a sequence number, filtered by aggregate and event name, and
# it reads every rotated generation so a cursor carries across a rotation.
RSpec.describe Hecks::Runtime::EventFeed do
  let(:dir) { Dir.mktmpdir("feed") }
  let(:path) { File.join(dir, "events.jsonl") }

  after { FileUtils.rm_rf(dir) }

  def line(seq, aggregate: "Hecks::RedFlag", event: "RedFlagRaised")
    { "kind" => "event", "seq" => seq, "aggregate" => aggregate, "id" => "x", "event" => event }
  end

  def write(file, *lines)
    File.write(file, lines.map { |entry| "#{JSON.generate(entry)}\n" }.join, mode: "a")
  end

  it "answers the lines past the cursor, in sequence" do
    write(path, line(1), line(2), line(3))
    expect(described_class.new(path: path).read(since: 1)[:events].map { |e| e["seq"] }).to eq([2, 3])
  end

  it "filters by aggregate, bare or qualified and case-insensitively" do
    write(path, line(1), line(2, aggregate: "Tickets::Work"))
    expect(described_class.new(path: path).read(aggregates: ["work"])[:events].map { |e| e["seq"] }).to eq([2])
  end

  it "filters by event name" do
    write(path, line(1), line(2, event: "RedFlagCleared"))
    expect(described_class.new(path: path).read(names: ["RedFlagCleared"])[:events].map { |e| e["seq"] }).to eq([2])
  end

  it "advances the cursor past lines the filter dropped" do
    write(path, line(1, aggregate: "Hecks::Landing"), line(2, aggregate: "Hecks::Landing"))
    expect(described_class.new(path: path).read(aggregates: ["RedFlag"])[:cursor]).to eq(2)
  end

  it "reads the rotated generations before the live file" do
    write("#{path}.2", line(1), line(2))
    write("#{path}.1", line(3))
    write(path, line(4))
    expect(described_class.new(path: path).read(since: 1)[:events].map { |e| e["seq"] }).to eq([2, 3, 4])
  end

  it "skips a line that does not parse" do
    File.write(path, "not json\n#{JSON.generate(line(1))}\n")
    expect(described_class.new(path: path).read[:events].map { |e| e["seq"] }).to eq([1])
  end

  it "answers nothing for a log that does not exist" do
    expect(described_class.new(path: path).read)
      .to eq({ events: [], cursor: 0, unnumbered: 0 })
  end
end
