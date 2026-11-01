require "spec_helper"
require_relative "../lib/hecks/quality_control/adapters/main_maintenance"

# A confirmed MintEra with a would_mint verdict reaches the mint entry point through the
# `AutoMintAdditive` policy and nothing refuses a reaction. QualityControl boots in Memory and the
# entry point's commands are stubbed, so no database or ledger is touched.
RSpec::Matchers.define_negated_matcher :not_include, :include

RSpec.describe "the QualityControl mint chain" do
  let(:qc) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false) }
  let(:commands) { Hecks::Adapters::MainMaintenance::Commands }
  let(:state_dir) { Dir.mktmpdir }
  let(:facts) do
    { watermark: 19, edge_text: "", verdict: nil, held: nil, current: nil, from: "a", to: "b" }
  end

  before do
    stub_const("Hecks::Adapters::MainMaintenance::STRANDED_DIR", File.join(state_dir, "state"))
    allow(commands).to receive_messages(auto_mint_facts: facts, mint_era: ["316ef0", true])
  end

  after { FileUtils.remove_entry(state_dir) }

  def mint_era
    Hecks::Adapters::Driving::CliRunner.call(
      runtime: qc, program: "hecks",
      argv: ["quality_control", "Maintenance.mint_era!", "run.value=mint-1", "domain=QualityControl", "era=13",
             "sha.value=#{"a" * 40}", "branch=", "rehearsal_ref=r", "watermark=19",
             "rehearsal_verdict.value=would_mint", "refusal_total=0", "confirm.value=true", "--wait"]
    ).first
  end

  it "reaches the mint entry point with no refused reaction", :aggregate_failures do
    out = mint_era
    expect(commands).to have_received(:mint_era)
    expect(out).to include("Minted").and(not_include("refused_reactions"))
  end
end
