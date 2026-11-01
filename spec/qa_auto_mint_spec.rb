require "hecks"
require "tmpdir"
require "fileutils"
require_relative "../lib/hecks/quality_control/adapters/main_maintenance"

# The auto-mint rule: a mint with no owner confirm runs only for an empty, additive, refusal-free
# rehearsal
# at the live watermark, and every other mint is held for the owner or refused by its guard.
module AutoMintSupport
  EMPTY_EDGE = %(Hecks.data_translation "Hecks", from: "5d288c", to: "f30dcb" do\nend\n).freeze
  FILLED_EDGE = %(Hecks.data_translation "Hecks", from: "5d288c", to: "f30dcb" do\n  drop "port"\nend\n).freeze
  NO_DIFF = { aggregates: [], retired: [], unclaimed: [] }.freeze
  BLUEBOOK = Struct.new(:aggregates).new([]).freeze

  def clean_facts(**overrides)
    { watermark: 19, from: "5d288c", to: "f30dcb", edge_text: EMPTY_EDGE, diff: NO_DIFF,
      held: BLUEBOOK, current: BLUEBOOK }.merge(overrides)
  end
end

RSpec.describe "the auto-mint rule" do
  include AutoMintSupport

  describe Hecks::Adapters::QaAutoMint do
    it "holds nothing for an empty additive edge with no refusals" do
      expect(described_class.held_reason(clean_facts, refusal_total: 0)).to be_nil
    end

    it "holds a mint whose edge declares a change" do
      expect(described_class.held_reason(clean_facts(edge_text: AutoMintSupport::FILLED_EDGE), refusal_total: 0))
        .to include("not empty")
    end

    it "holds a mint whose shape change is a rename" do
      rename = { aggregates: [Struct.new(:name, :was).new("Cart", "Basket")], retired: [], unclaimed: [] }
      expect(described_class.held_reason(clean_facts(diff: rename), refusal_total: 0)).to include("not additive")
    end

    it "holds a mint whose rehearsal refused rows" do
      expect(described_class.held_reason(clean_facts, refusal_total: 2)).to include("refused 2 rows")
    end
  end

  describe Hecks::Adapters::MainMaintenance do
    let(:state_dir) { Dir.mktmpdir("auto-mint") }

    before do
      stub_const("Hecks::Adapters::MainMaintenance::STRANDED_DIR", File.join(state_dir, "state"))
      allow(commands).to receive(:mint_era).and_return(["label", true])
    end

    after { FileUtils.remove_entry(state_dir) }

    def commands = Hecks::Adapters::MainMaintenance::Commands
    def refused = Hecks::Adapters::MainMaintenance::Refused
    def port = described_class.new(root: state_dir, commands: commands)

    def mint(confirm: nil, watermark: 19, refusal_total: 0)
      port.mint(run: "r1", domain: "Hecks", era: 20, sha: "a" * 40, branch: "", watermark: watermark,
                rehearsal_verdict: "would_mint", refusal_total: refusal_total, ledger_dir: "/ledger",
                confirm: confirm)
    end

    it "mints an empty additive rehearsal without the owner's confirm", :aggregate_failures do
      allow(commands).to receive(:auto_mint_facts).and_return(clean_facts)
      expect(mint).to include(label: { value: "label" })
      expect(commands).to have_received(:mint_era).with(anything, hash_including(request: hash_including(confirm: true)))
    end

    it "holds a mint the rule does not cover for the owner", :aggregate_failures do
      allow(commands).to receive(:auto_mint_facts).and_return(clean_facts(edge_text: nil))
      expect { mint }.to raise_error(refused, /needs owner approval/)
      expect(commands).not_to have_received(:mint_era)
    end

    it "runs a held mint once the owner confirms it" do
      allow(commands).to receive(:auto_mint_facts).and_return(clean_facts(edge_text: nil))
      expect(mint(confirm: { value: true })).to include(label: { value: "label" })
    end

    it "refuses a stale watermark rather than holding it" do
      allow(commands).to receive(:auto_mint_facts).and_return(clean_facts)
      expect { mint(watermark: 18) }.to raise_error(refused, /watermark moved from 18 to 19/)
    end

    it "refuses a mint while a stranded marker exists" do
      allow(commands).to receive(:auto_mint_facts).and_return(clean_facts)
      FileUtils.mkdir_p(File.join(state_dir, "state"))
      File.write(File.join(state_dir, "state", "stranded.json"), "{}")
      expect { mint }.to raise_error(refused, /stranded landing is resolved/)
    end
  end
end
