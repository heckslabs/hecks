require "spec_helper"
require "tmpdir"
require "json"
require "zlib"

# The usage record is trimmed once it is large: runs older than the window move to their month's
# gzip file, the runs inside the window stay, and nothing is lost.
RSpec.describe Hecks::Adapters::Driving::UsageLog::Trim do
  let(:dir) { Dir.mktmpdir("usage-trim") }
  let(:record) { File.join(dir, "usage.jsonl") }
  let(:now) { Time.utc(2026, 11, 20, 12) }

  after { FileUtils.rm_rf(dir) }

  def row(date, extra = {}) = JSON.generate({ "typed" => "x", "date" => date }.merge(extra))

  def write(*lines) = File.write(record, lines.map { |line| "#{line}\n" }.join)

  def kept = File.readlines(record, chomp: true)

  # Reads every gzip member of the file, which is how an archive added to over time reads.
  def archived(name) = File.open(File.join(dir, name), "rb") { |io| Zlib::GzipReader.zcat(io) }.lines(chomp: true)

  it "moves the runs older than the window to their month's archive and keeps the rest", :aggregate_failures do
    write(row("2026-09-30"), row("2026-10-05"), row("2026-10-25"), row("2026-11-19"))
    moved = described_class.run(record, window: 30, now: now)

    expect(moved).to eq(2)
    expect(kept).to eq([row("2026-10-25"), row("2026-11-19")])
    expect(archived("usage-202609.jsonl.gz") + archived("usage-202610.jsonl.gz")).to eq([row("2026-09-30"), row("2026-10-05")])
  end

  it "adds to an archive that exists, never replacing it" do
    write(row("2026-09-01"))
    described_class.run(record, window: 30, now: now)
    write(row("2026-09-02"), row("2026-11-19"))
    described_class.run(record, window: 30, now: now)

    expect(archived("usage-202609.jsonl.gz")).to eq([row("2026-09-01"), row("2026-09-02")])
  end

  it "keeps a line with no readable date rather than archiving it", :aggregate_failures do
    write("not json", JSON.generate("typed" => "x"), row("2026-01-01"))
    described_class.run(record, window: 30, now: now)

    expect(kept).to eq(["not json", JSON.generate("typed" => "x")])
    expect(archived("usage-202601.jsonl.gz")).to eq([row("2026-01-01")])
  end

  # Makes a record of twenty lines large enough to look at.
  def small_rotation = stub_const("#{described_class}::ROTATE_BYTES", 100)

  def large_record = write(*Array.new(20) { row("2026-11-19") })

  it "is not due while the record is small" do
    small_rotation
    write(row("2026-11-19"))

    expect(described_class.due?(record)).to be(false)
  end

  it "is due once the record is large" do
    small_rotation
    large_record

    expect(described_class.due?(record)).to be(true)
  end

  it "is not due again until the record has grown" do
    small_rotation
    large_record
    described_class.run(record, window: 30, now: now)

    expect(described_class.due?(record)).to be(false)
  end

  it "trims on append once the record is large, and keeps the run just recorded", :aggregate_failures do
    stub_const("#{described_class}::ROTATE_BYTES", 100)
    write(*Array.new(20) { row("2026-01-01") })
    record_one
    expect(kept.size).to eq(1)
    expect(archived("usage-202601.jsonl.gz").size).to eq(20)
  end

  # Records a run into this example's directory with the record switched on.
  def record_one
    saved = ENV.to_h.slice("HECKS_CACHE_DIR", "HECKS_USAGE")
    ENV["HECKS_CACHE_DIR"] = dir
    ENV.delete("HECKS_USAGE")
    Hecks::Adapters::Driving::UsageLog.record(argv: ["Workspace.status"], resolved: "workspace.status", status: 0,
                                              started: Process.clock_gettime(Process::CLOCK_MONOTONIC))
  ensure
    %w[HECKS_CACHE_DIR HECKS_USAGE].each { |name| saved.key?(name) ? ENV[name] = saved[name] : ENV.delete(name) }
  end

  it "does nothing to a record it cannot open" do
    expect(described_class.due?(File.join(dir, "missing.jsonl"))).to be(false)
  end
end
