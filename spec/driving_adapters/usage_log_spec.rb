require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Hecks::Adapters::Driving::UsageLog do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      saved = ENV.to_h.slice("HECKS_CACHE_DIR", "HECKS_USAGE")
      ENV["HECKS_CACHE_DIR"] = dir
      ENV.delete("HECKS_USAGE")
      example.run
      ENV.update(saved)
      ENV.delete("HECKS_USAGE") unless saved.key?("HECKS_USAGE")
    end
  end

  def run_once(argv = ["query", "Checkout.status"], resolved: "checkout.status", status: 0)
    described_class.record(argv: argv, resolved: resolved, status: status, started: Process.clock_gettime(Process::CLOCK_MONOTONIC))
  end

  def entries
    File.readlines(File.join(@dir, "usage.jsonl")).map { |line| JSON.parse(line) }
  end

  it "appends the name as typed, the resolved name, the status and the date" do
    run_once
    expect(entries.last).to include("typed" => "Checkout.status", "resolved" => "checkout.status", "status" => 0)
  end

  it "writes no arguments or values" do
    run_once(["Operation.run!", "name=secret"], resolved: "operation.run")
    expect(File.read(File.join(@dir, "usage.jsonl"))).not_to include("secret")
  end

  it "writes nothing when HECKS_USAGE is off" do
    ENV["HECKS_USAGE"] = "off"
    run_once
    expect(File.exist?(File.join(@dir, "usage.jsonl"))).to be(false)
  end

  it "writes nothing when the usage.off marker sits in the directory" do
    FileUtils.touch(File.join(@dir, "usage.off"))
    run_once
    expect(File.exist?(File.join(@dir, "usage.jsonl"))).to be(false)
  end

  it "prints the first-run line on the first run" do
    expect { run_once }.to output(/keeps a local record/).to_stderr
  end

  it "prints nothing once the notice marker exists" do
    run_once
    expect { run_once }.not_to output.to_stderr
  end

  it "does not raise when the directory cannot be written" do
    blocker = File.join(@dir, "blocker")
    FileUtils.touch(blocker)
    ENV["HECKS_CACHE_DIR"] = File.join(blocker, "sub")
    expect { run_once }.not_to raise_error
  end

  it "counts runs in the window and names the known ones that did not run" do
    run_once
    text = described_class.summary(known: ["checkout.status", "operation.run"])
    expect(text).to include("never run in that window:\n  operation.run")
  end
end
