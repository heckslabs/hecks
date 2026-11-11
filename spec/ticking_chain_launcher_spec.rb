require "spec_helper"
require "tmpdir"
require "rbconfig"
require "hecks/hecks/adapters/ticking"

# The child the `Ticking` port starts dispatches through the launcher with the arguments the
# launcher takes, and a refused dispatch ends the chain with a `Ticker.stop!` that names why.
RSpec.describe "the chain of ticks dispatching through the launcher" do
  let(:dir) { Dir.mktmpdir("ticking-chain") }
  let(:log) { File.join(dir, "calls.log") }

  after { FileUtils.remove_entry(dir) }

  def stub_launcher(refusal)
    path = File.join(dir, "hecks")
    File.write(path, <<~SH)
      #!/bin/sh
      echo "$@" >> #{log}
      case "$1" in Ticker.tick!) echo '[hecks] noise'; echo '#{refusal}'; exit 1;; esac
    SH
    File.chmod(0o755, path)
    path
  end

  def run_chain(launcher)
    system(RbConfig.ruby, "-e", Hecks::Adapters::Ticking::CHAIN, "run-x", "0", launcher, File.join(dir, "chain.log"))
    File.readlines(log, chomp: true)
  end

  it "ticks with the arguments the launcher takes", :aggregate_failures do
    calls = run_chain(stub_launcher("[refused] no"))
    expect(calls.first).to eq("Ticker.tick! to=run-x tick=run-x-1 beats=1")
  end

  it "stops the chain naming the launcher's refusal" do
    calls = run_chain(stub_launcher("[refused] the beats are within the limit"))
    expect(calls.last).to eq("Ticker.stop! to=run-x ending=[refused] the beats are within the limit")
  end
end
