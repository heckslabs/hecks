require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/in_process_boot"
require "hecks/runtime/event_tap"
require "hecks/runtime/event_log"

# `Operation.follow` tails the event tap when the domain's world declares one: every process's
# events, Memory domains included, with the payloads the tap carries, filtered by aggregate and
# counted by a cursor a later call continues from. A second reader is handed what the first was.
# The tap and the reader share the boot's override, so a spec run reads the file it writes.
RSpec.describe Hecks::Adapters::InProcessOperations, "#stream over the event tap" do
  let(:dir) { Dir.mktmpdir("hecks-follow-tap") }
  let(:path) { File.join(dir, "events.jsonl") }
  let(:log) { Hecks::Runtime::EventLog.new }
  let(:world) { Hecks::Bluebook::DSL::WorldBuilder.build("Hecks") { event_log "EventTap", path: "unused.jsonl", payloads: %w[RedFlag] } }
  let(:registry) { instance_double(Hecks::Runtime::Registry, world: world, event_log: log) }

  before do
    allow(Hecks::Assembly).to receive(:event_tap_override).and_return(path)
    Hecks::Runtime::EventTap.install(registry, override: path)
    log << event("RedFlagRaised")
    log << event("AddRequested", aggregate: "Hecks::LinkedTree", payload: { branch: { value: "b" } })
  end

  after { FileUtils.rm_rf(dir) }

  def event(name, aggregate: "Hecks::RedFlag", payload: { flag: { value: "flag-2dc207c705" } })
    Hecks::Runtime::Event.new(name: name, aggregate: aggregate, id: "r1", payload: payload, occurred_at: "2026-11-02T22:54:29Z")
  end

  # What one reader sees past `since`, and the cursor it ends at.
  def tail(since: 0, aggregate: nil)
    seen = []
    reader = Hecks::Adapters::InProcessBoot.new
    cursor = reader.stream(domain: dir, aggregate: aggregate, since: since, timeout: 0, registry: registry) do |entry|
      seen << entry
      :batch
    end
    [cursor, seen]
  end

  it "reads the tap the world declares, with the payload it carries for a listed aggregate", :aggregate_failures do
    _cursor, seen = tail

    expect(seen.map { |entry| entry["name"] }).to eq(%w[RedFlagRaised AddRequested])
    expect(seen.first["payload"]).to eq("flag" => { "value" => "flag-2dc207c705" })
    expect(seen.last["payload"]).to eq({})
  end

  it "filters by aggregate and answers a cursor a later call continues from", :aggregate_failures do
    cursor, seen = tail(aggregate: "RedFlag")

    expect(seen.map { |entry| entry["name"] }).to eq(%w[RedFlagRaised])
    expect(cursor).to eq(2)
    expect(tail(since: cursor).last).to be_empty
  end

  it "hands a second reader what the first was handed", :aggregate_failures do
    _first_cursor, first = tail
    _second_cursor, second = tail

    expect(second).to eq(first)
    expect(first.size).to eq(2)
  end

  it "reads the file the boot's override names, the one this process writes" do
    expect(File.exist?(path)).to be(true)
  end
end
