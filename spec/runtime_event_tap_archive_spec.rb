# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/runtime/event_tap"

# The tap's archive: a generation past the last numbered file is compressed beside the log with
# its repeats folded, kept for `keep_hours` and bounded by `archive_max_bytes`, so the tap still
# holds yesterday's events. Every file here is under a temporary directory.
RSpec.describe Hecks::Runtime::EventTap::Archive do
  let(:dir) { Dir.mktmpdir("tap-archive") }
  let(:path) { File.join(dir, "events.jsonl") }
  let(:archive) { described_class.new(path, keep_hours: 48, max_bytes: 1_000_000) }

  after { FileUtils.rm_rf(dir) }

  def tap(**limits) = Hecks::Runtime::EventTap.new(path: path, max_bytes: 200, **limits)

  def event(id = "t1", at = "2026-11-12T10:00:00Z")
    Hecks::Runtime::Event.new(name: "TidyRequested", aggregate: "Hecks::AgentRun", id: id, payload: {},
                              occurred_at: at)
  end

  # Writes a generation of the given lines, last written at the given time, and archives it.
  def archived(lines, written: Time.now)
    file = "#{path}.5"
    File.write(file, lines.map { |line| "#{JSON.generate(line)}\n" }.join)
    File.utime(written, written, file)
    archive.store(file)
  end

  def line(seq, at, id: "t1") = { "kind" => "event", "at" => at, "id" => id, "event" => "TidyRequested", "seq" => seq }

  def stored = archive.lines.map { |text| JSON.parse(text) }

  it "archives the generation a rotation pushes past the last numbered file", :aggregate_failures do
    writer = tap
    40.times { |n| writer.event(event("run-#{n}")) }
    expect(writer.archive.files).not_to be_empty
    expect(File.exist?("#{path}.#{Hecks::Runtime::EventTap::KEPT}")).to be(true)
  end

  it "holds every line between the archive and the files beside the log" do
    writer = tap
    40.times { |n| writer.event(event("run-#{n}")) }
    plain = Dir.glob("#{path}*").select { |file| File.file?(file) && !file.end_with?(".lock") }
    expect(writer.archive.lines.size + plain.sum { |file| File.readlines(file).size }).to eq(40)
  end

  it "keeps the sequence unbroken while generations are archived" do
    writer = tap
    40.times { |n| writer.event(event("run-#{n}")) }
    expect(JSON.parse(File.readlines(path).last)["seq"]).to eq(40)
  end

  it "removes the generation once its archive file is in place", :aggregate_failures do
    target = archived([line(1, "2026-11-12T10:00:00Z")])
    expect(File.exist?("#{path}.5")).to be(false)
    expect(File.basename(target)).to match(/\A\d{8}T\d{6}Z-1\.jsonl\.gz\z/)
  end

  it "folds a line repeated within the gap into its first, counted and timed", :aggregate_failures do
    archived([line(1, "2026-11-12T10:00:00Z"), line(2, "2026-11-12T10:01:00Z"), line(3, "2026-11-12T10:02:00Z")])
    expect(stored.size).to eq(1)
    expect(stored.first).to include("seq" => 1, "repeats" => 2, "last_at" => "2026-11-12T10:02:00Z")
  end

  it "keeps apart the lines of different identities" do
    archived([line(1, "2026-11-12T10:00:00Z"), line(2, "2026-11-12T10:00:00Z", id: "t2")])
    expect(stored.map { |held| held["id"] }).to eq(%w[t1 t2])
  end

  it "starts a new line after a silence longer than the gap, so a stop still shows" do
    archived([line(1, "2026-11-12T10:00:00Z"), line(2, "2026-11-12T10:01:00Z"), line(3, "2026-11-12T16:00:00Z")])
    expect(stored.map { |held| held["at"] }).to eq(%w[2026-11-12T10:00:00Z 2026-11-12T16:00:00Z])
  end

  it "keeps a line that is not JSON as it is" do
    File.write("#{path}.5", "not json\n")
    archive.store("#{path}.5")
    expect(archive.lines).to eq(["not json"])
  end

  it "still holds a generation written yesterday" do
    archived([line(1, "2026-11-12T10:00:00Z")], written: Time.now - (30 * 3600))
    expect(stored.size).to eq(1)
  end

  it "drops a generation older than the hours kept" do
    archived([line(1, "2026-11-10T10:00:00Z")], written: Time.now - (49 * 3600))
    expect(archive.files).to be_empty
  end

  it "drops the oldest files past the byte limit and keeps the newest" do
    small = described_class.new(path, keep_hours: 48, max_bytes: 1)
    archived([line(1, "2026-11-12T10:00:00Z")], written: Time.now - 7200)
    new = archived([line(2, "2026-11-12T12:00:00Z")], written: Time.now - 3600)
    small.prune
    expect(small.files).to eq([new])
  end

  it "drops the oldest generation, as a tap without an archive does, when the archive cannot be written" do
    File.write("#{path}.archive", "a file where the directory would be")
    writer = tap
    expect { 40.times { |n| writer.event(event("run-#{n}")) } }.not_to raise_error
  end

  it "reads keep_hours and archive_max_bytes from the world's event_log", :aggregate_failures do
    declared = Hecks::Bluebook::DSL::WorldBuilder.build("Hecks") { event_log "EventTap", path: "x", keep_hours: 72 }
    limits = Hecks::Runtime::EventTap::LIMITS.merge(declared.for_verb("event_log").to_h.slice(:keep_hours))
    expect(limits).to include(keep_hours: 72, archive_max_bytes: 200_000_000)
  end
end
