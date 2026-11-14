require "spec_helper"
require "tmpdir"
require "rbconfig"
require "hecks/hecks/adapters/ticking"

# Every launcher line the chain runs names its caller, and the child is told which branch to watch.
RSpec.describe "the chain of ticks naming its caller" do
  let(:dir) { Dir.mktmpdir("ticking-caller") }

  after { FileUtils.remove_entry(dir) }

  def spawned
    seen = []
    settings = { spawner: ->(*a) { seen.replace(a) }, dir: dir, seconds: 20, minutes: 30, persisted: true }
    Hecks::Adapters::Ticking.new(root: File.expand_path("..", __dir__), settings: settings).open(run: "0123456789abcdef")
    seen
  end

  it "starts the child with the caller, the schedule and the branch" do
    expect(spawned.first).to include("HECKS_CALLER" => "ticker", "HECKS_TICK_WATCH" => "train/main-0123456789ab")
  end

  it "has the launcher see HECKS_CALLER=ticker on a tick" do
    launcher = File.join(dir, "hecks")
    File.write(launcher, "#!/bin/sh\necho \"$HECKS_CALLER\" >> #{dir}/who\nexit 1\n")
    File.chmod(0o755, launcher)
    system(RbConfig.ruby, "-e", Hecks::Adapters::Ticking::CHAIN, "run-x", "0", launcher, File.join(dir, "log"))
    expect(File.read(File.join(dir, "who")).split).to eq(%w[ticker ticker])
  end
end
