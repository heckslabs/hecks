require "hecks"
require "tmpdir"
require "fileutils"
require_relative "../lib/hecks/quality_control/adapters/main_maintenance"

# The watermark guard of the Maintenance mint. The mint command saves the run's own `Maintenance`
# record before the entry point runs, so that one journal row is not a change the rehearsal missed;
# a row from anything else still is. The ledger is stubbed: `own_rows_after` answers how many rows
# the run's record wrote above the rehearsed watermark.
RSpec.describe Hecks::Adapters::MainMaintenance, "#mint watermark guard" do
  let(:refused) { Hecks::Adapters::MainMaintenance::Refused }
  let(:state_dir) { Dir.mktmpdir("own-record") }
  let(:commands) { Hecks::Adapters::MainMaintenance::Commands }
  let(:port) { described_class.new(root: state_dir, commands: commands) }

  before do
    stub_const("Hecks::Adapters::MainMaintenance::STRANDED_DIR", File.join(state_dir, "state"))
    allow(commands).to receive(:mint_era).and_return(["label", true])
  end

  after { FileUtils.remove_entry(state_dir) }

  # A ledger at `live`, of which `own` rows above the rehearsed watermark are the run's record.
  def ledger(live:, own:)
    allow(commands).to receive_messages(auto_mint_facts: { watermark: live }, own_rows_after: own)
  end

  def mint
    port.mint(run: "r1", domain: "Ledger", era: 2, sha: "a" * 40, branch: "", watermark: 10,
              rehearsal_verdict: "would_mint", confirm: { value: true })
  end

  it "passes when the one extra row is the run's own record, and mints at the live watermark" do
    ledger(live: 11, own: 1)
    mint
    expect(commands).to have_received(:mint_era).with(anything, hash_including(request: hash_including(watermark: 11)))
  end

  it "refuses when the one extra row is another record's" do
    ledger(live: 11, own: 0)
    expect { mint }.to raise_error(refused, /watermark moved from 10 to 11 since the rehearsal/)
  end

  it "refuses when one extra row is the run's own and another is not" do
    ledger(live: 12, own: 1)
    expect { mint }.to raise_error(refused, /watermark moved from 10 to 12 since the rehearsal/)
  end

  it "passes when the ledger has not moved" do
    ledger(live: 10, own: 0)
    expect(mint).to include(label: { value: "label" })
  end

  it "refuses a ledger that moved back" do
    ledger(live: 9, own: 0)
    expect { mint }.to raise_error(refused, /watermark moved from 10 to 9/)
  end
end
