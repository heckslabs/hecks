# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/runtime/event_tap"
require "hecks/runtime/event_log"

# The opt-in event log: off unless the Hecks world declares `event_log`, then one JSON line per
# event and per policy delivery, never a payload, rotated by size, and never a refused command.
# An override handed in at boot (the Assembly reads it from `HECKS_EVENT_TAP`) moves a declared
# tap or, empty, switches it off.
RSpec.describe Hecks::Runtime::EventTap do
  let(:dir) { Dir.mktmpdir("tap") }
  let(:path) { File.join(dir, "events.jsonl") }
  let(:log) { Hecks::Runtime::EventLog.new }

  after { FileUtils.rm_rf(dir) }

  def world(**settings)
    Hecks::Bluebook::DSL::WorldBuilder.build("Hecks") { event_log "EventTap", **settings }
  end

  def registry_with(declared)
    instance_double(Hecks::Runtime::Registry, world: declared, event_log: log)
  end

  def event(name = "AddRequested")
    Hecks::Runtime::Event.new(name: name, aggregate: "Hecks::LinkedTree", id: "t1", payload: { secret: "x" },
                              occurred_at: "2026-11-02T10:00:00Z")
  end

  def lines = File.readlines(path).map { |text| JSON.parse(text) }

  it "installs nothing when no world declares an event log", :aggregate_failures do
    expect(described_class.install(registry_with(nil))).to be_nil
    expect(File.exist?(path)).to be(false)
  end

  it "writes where the override points, not where the world does", :aggregate_failures do
    moved = File.join(dir, "moved.jsonl")
    described_class.install(registry_with(world(path: path)), override: moved)
    log << event

    expect(File.exist?(moved)).to be(true)
    expect(File.exist?(path)).to be(false)
  end

  it "installs nothing when the override is empty" do
    expect(described_class.install(registry_with(world(path: path)), override: "")).to be_nil
  end

  it "leaves a world that declares no path alone, whatever the override says" do
    expect(described_class.install(registry_with(world(path: "")), override: path)).to be_nil
  end

  it "writes one line for each event appended to the registry's log" do
    described_class.install(registry_with(world(path: path)))
    log << event
    expect(lines).to eq([{ "kind" => "event", "at" => "2026-11-02T10:00:00Z", "aggregate" => "Hecks::LinkedTree",
                           "id" => "t1", "event" => "AddRequested", "correlation" => {}, "links" => {}, "seq" => 1 }])
  end

  it "numbers each line with the next sequence" do
    described_class.install(registry_with(world(path: path)))
    2.times { log << event }
    expect(lines.map { |line| line["seq"] }).to eq([1, 2])
  end

  it "continues the sequence after a restart" do
    2.times { described_class.install(registry_with(world(path: path))).then { log << event } }
    expect(lines.map { |line| line["seq"] }).to eq([1, 2])
  end

  it "writes names and outcomes but never a payload" do
    described_class.install(registry_with(world(path: path)))
    log << event
    expect(File.read(path)).not_to include("secret")
  end

  it "writes the link keys of a payload and nothing else of it" do
    described_class.install(registry_with(world(path: path)))
    log << linked_event
    expect(File.read(path).scan(%r{feature/x|hidden})).to eq(["feature/x"])
  end

  it "writes the saga correlation beside the event" do
    described_class.install(registry_with(world(path: path)))
    log << linked_event
    expect(JSON.parse(File.read(path).lines.first)["correlation"]).to eq("landed.value" => "a1b2c3d")
  end

  def linked_event
    Hecks::Runtime::Event.new(name: "BranchLanded", aggregate: "Hecks::Landing", id: "l1",
                              payload: { branch: { value: "feature/x" }, landed: "a1b2c3d", hidden: "hidden" },
                              occurred_at: "2026-11-02T10:00:00Z", correlation: { "landed.value" => "a1b2c3d" })
  end

  it "writes one line for each policy delivery, with the command it reached and its outcome" do
    described_class.install(registry_with(world(path: path)))
    log.reaction_observer.call({ policy: "AddWorktree", on: "AddRequested", trigger: "LinkedTree.Create", delivered: true }, "t1")
    expect(lines.first).to include("kind" => "reaction", "policy" => "AddWorktree", "outcome" => "delivered")
  end

  it "records a refused delivery with its reason" do
    described_class.install(registry_with(world(path: path)))
    log.reaction_observer.call({ policy: "P", on: "E", trigger: "A.B", delivered: false, reason: "no" }, "t1")
    expect(lines.first["outcome"]).to eq("refused: no")
  end

  it "moves the log aside once it holds max_bytes" do
    described_class.install(registry_with(world(path: path, max_bytes: 200)))
    4.times { log << event }
    expect(File.exist?("#{path}.1")).to be(true)
  end

  it "keeps older generations instead of overwriting them" do
    described_class.install(registry_with(world(path: path, max_bytes: 200)))
    12.times { log << event }
    expect(File.exist?("#{path}.2")).to be(true)
  end

  it "keeps the sequence unbroken across a rotation" do
    described_class.install(registry_with(world(path: path, max_bytes: 200)))
    12.times { log << event }
    expect(lines.last["seq"]).to eq(12)
  end

  it "continues the sequence when the tail it reads starts inside a multi-byte character" do
    head = %({"seq":1,"pad":")
    last = %({"seq":7}\n)
    pad = "é" * 40_000
    size = head.bytesize + pad.bytesize + 3 + last.bytesize
    pad = "#{pad}a" if (size - described_class::TAIL_BYTES - head.bytesize).even?
    File.write(path, "#{head}#{pad}\"}\n#{last}")
    described_class.install(registry_with(world(path: path)))
    log << event
    expect(lines.last["seq"]).to eq(8)
  end

  it "drops a write that fails instead of raising" do
    File.write(path, "x")
    described_class.install(registry_with(world(path: File.join(path, "below-a-file.jsonl"))))
    expect { log << event }.not_to raise_error
  end
end
