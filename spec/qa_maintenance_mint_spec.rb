require "hecks"
require "tmpdir"
require "fileutils"
require_relative "../lib/hecks/quality_control/adapters/main_maintenance"

# The maintainer's mint and landing: a mint lands on main in the same step, a failed landing
# strands the run, and a stranded run refuses every later mint until the owner removes its marker.
RSpec.describe Hecks::Adapters::MainMaintenance do
  let(:refused) { Hecks::Adapters::MainMaintenance::Refused }
  let(:state_dir) { Dir.mktmpdir("mint-state") }
  let(:commands) { Hecks::Adapters::MainMaintenance::Commands }
  let(:port) { described_class.new(root: state_dir, commands: commands) }

  after { FileUtils.remove_entry(state_dir) }

  before do
    stub_const("Hecks::Adapters::MainMaintenance::STRANDED_DIR", File.join(state_dir, "state"))
    allow(commands).to receive_messages(auto_mint_facts: { watermark: 7 }, own_rows_after: 0)
  end

  def mint(verdict: "would_mint")
    port.mint(run: "r1", domain: "Ledger", era: 2, sha: "a" * 40, branch: "qa/x", watermark: 7,
              rehearsal_verdict: verdict, confirm: { value: true })
  end

  def land(stub_result)
    allow(commands).to receive(:land).and_return(stub_result)
    port.land(run: "r1", era: 2, sha: "a" * 40, branch: "qa/x")
  end

  it "refuses a mint whose rehearsal did not say would_mint" do
    expect { mint(verdict: "would_refuse") }.to raise_error(refused, /not would_mint/)
  end

  it "lands a minted era without stranding the run" do
    land(["merged", true])
    expect(File.exist?(File.join(state_dir, "state", "stranded.json"))).to be(false)
  end

  it "strands the run when the landing fails", :aggregate_failures do
    expect { land(["conflict on main", false]) }.to raise_error(refused, /landing failed after the mint of era 2/)
    expect(File.read(File.join(state_dir, "state", "stranded.json"))).to include("conflict on main")
  end

  it "refuses the next mint by name while the stranded run is unresolved", :aggregate_failures do
    expect { land(["conflict on main", false]) }.to raise_error(refused)
    allow(commands).to receive(:mint_era).and_return(["label", true])
    expect { mint }.to raise_error(refused, /stranded landing is resolved/)
  end

  it "mints again once the owner removes the marker", :aggregate_failures do
    expect { land(["conflict on main", false]) }.to raise_error(refused)
    FileUtils.rm_f(File.join(state_dir, "state", "stranded.json"))
    allow(commands).to receive(:mint_era).and_return(["label", true])
    expect(mint).to include(label: { value: "label" })
  end
end
