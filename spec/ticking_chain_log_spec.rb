require "spec_helper"
require "tmpdir"
require "rbconfig"
require "hecks/hecks/adapters/ticking"

# Drives the chain of ticks against a stand-in launcher and reads the log it writes.
module TickingLogHelpers
  def launcher(body)
    path = File.join(dir, "hecks")
    File.write(path, "#!/bin/sh\necho \"$@\" >> #{File.join(dir, "calls.log")}\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def run_chain(path)
    system(RbConfig.ruby, "-e", Hecks::Adapters::Ticking::CHAIN, "run-x", "0", path, log)
    File.readlines(File.join(dir, "calls.log"), chomp: true)
  end

  def argv_for(run)
    argv = []
    settings = { spawner: ->(*a) { argv.replace(a) }, dir: File.join(dir, "logs") }
    Hecks::Adapters::Ticking.new(root: File.expand_path("..", __dir__), settings: settings).open(run: run)
    argv
  end
end

# A chain of ticks writes its beginning, each tick's status and its end to the log file it is
# given, and the port tells the child where that file is, so a chain that dies can be read.
RSpec.describe "the chain of ticks and its log file" do
  include TickingLogHelpers

  let(:dir) { Dir.mktmpdir("ticking-log") }
  let(:log) { File.join(dir, "chain.log") }

  after { FileUtils.remove_entry(dir) }

  it "logs the beginning, the tick's status and the end", :aggregate_failures do
    run_chain(launcher('case "$1" in Ticker.tick!) echo "[refused] no"; exit 1;; esac'))
    expect(File.read(log)).to include("chain begun for run-x", "tick 1: exit 1", "ended: [refused] no")
  end

  it "names the exit status when the launcher refuses without a line" do
    calls = run_chain(launcher('case "$1" in Ticker.tick!) exit 3;; esac'))
    expect(calls.last).to eq("Ticker.stop! to=run-x ending=the launcher exited 3 without a refusal")
  end

  it "gives the child the log path as its last argument, its directory created", :aggregate_failures do
    expect(argv_for("r/1").last).to eq(File.join(dir, "logs", "r_1.log"))
    expect(File.directory?(File.join(dir, "logs"))).to be(true)
  end
end
