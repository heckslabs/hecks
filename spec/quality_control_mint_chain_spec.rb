require "spec_helper"
require_relative "../lib/hecks/quality_control/adapters/main_maintenance"

# A confirmed MintEra with a would_mint verdict reaches the mint entry point through the
# `AutoMintAdditive` policy and nothing refuses a reaction. QualityControl boots in Memory and the
# entry point's commands are stubbed, so no database or ledger is touched.
RSpec::Matchers.define_negated_matcher :not_include, :include

RSpec.describe "the QualityControl mint chain" do
  let(:qc) { boot_hecks_in_memory }
  let(:commands) { Hecks::Adapters::MainMaintenance::Commands }
  let(:state_dir) { Dir.mktmpdir }
  let(:facts) do
    { watermark: 19, edge_text: "", verdict: nil, held: nil, current: nil, from: "a", to: "b" }
  end

  before do
    stub_const("Hecks::Adapters::MainMaintenance::STRANDED_DIR", File.join(state_dir, "state"))
    allow(commands).to receive_messages(auto_mint_facts: facts, own_rows_after: 0, mint_era: ["316ef0", true])
    allow(Hecks::Adapters::QaRevisionMint).to receive(:disposable?).and_return(false)
  end

  after { FileUtils.remove_entry(state_dir) }

  def mint_era(*extra, branch: "")
    Hecks::Adapters::Driving::CliRunner.call(
      runtime: qc, program: "hecks",
      argv: ["quality_control", "Maintenance.mint_era!", "run.value=mint-1", "domain=QualityControl", "era=13",
             "sha.value=#{"a" * 40}", "branch=#{branch}", "rehearsal_ref=r", "watermark=19",
             "rehearsal_verdict.value=would_mint", "refusal_total=0", "confirm.value=true", *extra, "--wait"]
    ).first
  end

  it "reaches the mint entry point with no refused reaction", :aggregate_failures do
    out = mint_era
    expect(commands).to have_received(:mint_era)
    expect(out).to include("Minted").and(not_include("refused_reactions"))
  end

  it "mints the QualityControl ledger when the call names no ledger" do
    mint_era
    expect(commands).to have_received(:mint_era)
      .with(anything, hash_including(ledger: end_with(File.join("qa", "bluebook"))))
  end

  context "when the call names another domain's ledger" do
    # A client repository holding the ledger, made fresh for each example.
    def client_ledger
      @client = Dir.mktmpdir
      system("git", "init", "-q", @client, exception: true)
      File.join(@client, "bluebook").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    before { allow(commands).to receive(:land).and_return(["landed", true]) }

    after { FileUtils.remove_entry(@client) }

    it "mints that ledger, not the QualityControl one" do
      ledger = client_ledger
      mint_era("ledger_dir=#{ledger}")
      expect(commands).to have_received(:mint_era).with(anything, hash_including(ledger: ledger))
    end

    it "lands the branch in the repository that holds the ledger", :aggregate_failures do
      out = mint_era("ledger_dir=#{client_ledger}", branch: "era-edge")
      expect(commands).to have_received(:land).with(File.realpath(@client), "era-edge")
      expect(out).to include("Landed").and(not_include("refused_reactions"))
    end
  end

  it "leaves a mint-only run's gate colour and reconcile verdict optional", :aggregate_failures do
    attributes = qc.bluebook("QualityControl").aggregate("Maintenance").attributes
    expect(attributes.select { |attribute| %i[color verdict].include?(attribute.name.to_sym) }.map(&:optional?))
      .to eq([true, true])
  end
end
