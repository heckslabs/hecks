require "spec_helper"
require "tmpdir"
require "fileutils"

# A launcher's help is remembered under a digest of everything it depends on, so a repeat run
# skips reading the domain and any edit to what it reads is a different entry.
RSpec.describe Hecks::Doors::UsageCache do
  let(:cache) { Dir.mktmpdir("usage-cache-entries") }
  let(:domain) { Dir.mktmpdir("usage-cache-domain") }
  let(:runtime) { Struct.new(:directory).new(domain) }
  let(:calls) { [] }

  before do
    File.write(File.join(domain, "shop.bluebook"), "Hecks.bluebook \"Shop\" do\nend\n")
    @saved = ENV.to_h.slice("HECKS_CACHE_DIR", "HECKS_NO_USAGE_CACHE")
    ENV["HECKS_CACHE_DIR"] = cache
    ENV.delete("HECKS_NO_USAGE_CACHE")
  end

  after do
    ENV.delete("HECKS_NO_USAGE_CACHE")
    ENV["HECKS_CACHE_DIR"] = @saved["HECKS_CACHE_DIR"]
    ENV["HECKS_NO_USAGE_CACHE"] = @saved["HECKS_NO_USAGE_CACHE"] if @saved["HECKS_NO_USAGE_CACHE"]
    FileUtils.rm_rf([cache, domain])
  end

  def fetch(argv = [], &block)
    described_class.fetch(runtime, argv, "hecks", &block)
  end

  # What working the help out answers; it also notes that the domain was read.
  def worked_out(text, status = 0)
    calls << text
    [text, status]
  end

  # Backdates the only entry past the sweep window and returns its path.
  def age_first_entry
    stale = Dir.glob(File.join(cache, "usage-*.json")).first
    long_ago = Time.now - (described_class::KEEP_SECONDS + 60)
    File.utime(long_ago, long_ago, stale)
    stale
  end

  it "works the help out once and answers the repeat from the file, without running the block", :aggregate_failures do
    first = fetch { worked_out("help text") }
    again = fetch { raise "the domain was read again" }

    expect(first).to eq(["help text", 0])
    expect(again).to eq(["help text", 0])
    expect(calls.size).to eq(1)
  end

  it "treats an edit to a declaration file as a different entry" do
    fetch { worked_out("old help") }
    sleep 0.01
    File.write(File.join(domain, "shop.bluebook"), "Hecks.bluebook \"Shop\" do\n  # edited\nend\n")

    expect(fetch { worked_out("new help") }).to eq(["new help", 0])
  end

  it "keeps a separate entry for each audience, since the same line reads differently to each", :aggregate_failures do
    for_audience = ->(audience, &block) { described_class.fetch(runtime, [], "hecks", audience: audience, &block) }
    for_audience.call("project") { worked_out("project help") }
    for_audience.call("maintainer") { worked_out("maintainer help") }

    expect(for_audience.call("project") { raise "read again" }).to eq(["project help", 0])
    expect(for_audience.call("maintainer") { raise "read again" }).to eq(["maintainer help", 0])
  end

  it "keeps a separate entry for each command line", :aggregate_failures do
    fetch([]) { worked_out("usage") }
    fetch(["--help"]) { worked_out("help flag") }

    expect(fetch([]) { raise "read again" }).to eq(["usage", 0])
    expect(fetch(["--help"]) { raise "read again" }).to eq(["help flag", 0])
  end

  it "does not remember an answer that failed, or a line that runs something", :aggregate_failures do
    expect(fetch { worked_out("no such command", 1) }).to eq(["no such command", 1])
    expect(fetch { nil }).to be_nil
    fetch { worked_out("ok") }
    fetch { worked_out("ok") }

    expect(calls.size).to eq(2)
  end

  it "is off when HECKS_NO_USAGE_CACHE is set, and writes nothing", :aggregate_failures do
    ENV["HECKS_NO_USAGE_CACHE"] = "1"
    2.times { fetch { worked_out("help") } }

    expect(calls.size).to eq(2)
    expect(Dir.glob(File.join(cache, "*"))).to be_empty
  end

  it "passes over a runtime that names no directory, such as a booted domain" do
    2.times { described_class.fetch(Object.new, [], "hecks") { worked_out("help") } }

    expect(calls.size).to eq(2)
  end

  it "ignores an entry it cannot read and works the help out again" do
    fetch { worked_out("help") }
    Dir.glob(File.join(cache, "usage-*.json")).each { |entry| File.write(entry, "not json") }

    expect(fetch { worked_out("fresh") }).to eq(["fresh", 0])
  end

  it "sweeps entries nobody has read for two weeks when it writes a new one" do
    fetch(["old"]) { worked_out("stale") }
    stale = age_first_entry

    fetch(["new"]) { worked_out("fresh") }

    expect(File.exist?(stale)).to be(false)
  end

  it "does not stop the help when the cache directory cannot be written" do
    ENV["HECKS_CACHE_DIR"] = File.join(domain, "shop.bluebook", "beneath-a-file")

    expect(fetch { worked_out("help") }).to eq(["help", 0])
  end
end
