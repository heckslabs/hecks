# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/runtime/event_tap"
require "hecks/runtime/event_log"

# The opt-in event log: off unless the Hecks world declares `event_log`, then one JSON line per
# event and per policy delivery, never a payload, rotated by size, and never a refused command.
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

  it "writes one line for each event appended to the registry's log" do
    described_class.install(registry_with(world(path: path)))
    log << event
    expect(lines).to eq([{ "kind" => "event", "at" => "2026-11-02T10:00:00Z", "aggregate" => "Hecks::LinkedTree",
                           "id" => "t1", "event" => "AddRequested" }])
  end

  it "writes names and outcomes but never a payload" do
    described_class.install(registry_with(world(path: path)))
    log << event
    expect(File.read(path)).not_to include("secret")
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

  it "drops a write that fails instead of raising" do
    File.write(path, "x")
    described_class.install(registry_with(world(path: File.join(path, "below-a-file.jsonl"))))
    expect { log << event }.not_to raise_error
  end
end
