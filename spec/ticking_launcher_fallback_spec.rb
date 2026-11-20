require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/ticking"

# Builds a root checkout and reads which launcher the `Ticking` port's child is spawned with.
module TickingLauncherFallback
  # @return [String] an `exe/hecks`-shaped file at `path` with `mode`
  def launcher_at(path, mode: 0o755)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n")
    File.chmod(mode, path)
    path
  end

  # @return [String] the launcher the child would run, given the settings' standins
  def spawned_launcher(**standins)
    seen = []
    settings = { spawner: ->(*a) { seen.replace(a) }, dir: root, persisted: true, **standins }
    Hecks::Adapters::Ticking.new(root: root, settings: settings).open(run: "0123456789abcdef")
    seen[6] # env, ruby, -e, the chain, the run, the period, then the launcher
  end
end

# A project that boards its train through the Hecks launcher has no `exe/hecks` of its own, so
# the chain dispatches through the Hecks checkout's launcher. Only the launcher's path changes:
# the child is spawned with no `chdir`, so its ticks keep the root's working directory.
RSpec.describe "the chain of ticks finding a launcher" do
  include TickingLauncherFallback

  let(:root) { Dir.mktmpdir("ticking-root") }
  let(:hecks) { File.join(root, "hecks-launcher") }

  after { FileUtils.remove_entry(root) }

  it "dispatches through the root's own launcher when it has one" do
    own = launcher_at(File.join(root, "exe", "hecks"))
    expect(spawned_launcher(fallback: hecks)).to eq(own)
  end

  it "falls back to the Hecks checkout's launcher when the root has none" do
    expect(spawned_launcher(fallback: hecks)).to eq(hecks)
  end

  it "falls back past a root launcher that is not executable" do
    launcher_at(File.join(root, "exe", "hecks"), mode: 0o644)
    expect(spawned_launcher(fallback: hecks)).to eq(hecks)
  end

  it "refuses naming the root's launcher when neither is there" do
    expect { spawned_launcher(fallback: nil) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{no launcher at #{root}/exe/hecks})
  end

  it "falls back to the main checkout's launcher by default" do
    expect(spawned_launcher).to eq(Hecks::Adapters::MainLauncher.path)
  end
end
