require "spec_helper"
require "timeout"
require "tmpdir"
require "rbconfig"
require "hecks/hecks/adapters/ticking"

# A chain that nothing else ends (its pull request was never observed, as when a pull rewrote the
# boarded tip) still ends once it has ticked for the minutes the world allows, and the log says so.
RSpec.describe "the chain of ticks and its wall-clock bound" do
  let(:dir) { Dir.mktmpdir("ticking-bound") }
  let(:log) { File.join(dir, "chain.log") }
  let(:calls) { File.join(dir, "calls.log") }

  after { FileUtils.remove_entry(dir) }

  def launcher
    path = File.join(dir, "hecks")
    File.write(path, "#!/bin/sh\necho \"$@\" >> #{calls}\n")
    File.chmod(0o755, path)
    path
  end

  def run_chain(minutes)
    argv = ["run-x", "0", launcher, *minutes, log]
    Timeout.timeout(20) { system(RbConfig.ruby, "-e", Hecks::Adapters::Ticking::CHAIN, *argv) }
    File.readlines(calls, chomp: true)
  end

  it "stops a chain past its minutes, naming the bound in the stop", :aggregate_failures do
    expect(run_chain("0").last).to start_with("Ticker.stop! to=run-x ending=the chain outlived its 0 minutes")
    expect(File.read(log)).to include("ended: the chain outlived its 0 minutes after 0 ticks")
  end

  it "passes the minutes to the child before the log path" do
    argv = []
    settings = { spawner: ->(*a) { argv.replace(a) }, dir: File.join(dir, "logs"), seconds: 20, minutes: 30 }
    Hecks::Adapters::Ticking.new(root: File.expand_path("..", __dir__), settings: settings).open(run: "r")
    expect(argv[-2]).to eq("30.0")
  end
end
