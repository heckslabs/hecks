require "hecks"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/journal_store/auto_mint"

# The auto-mint rule: a mint with no owner confirm runs only for an empty, additive, refusal-free
# rehearsal, and every other mint is held for the owner.
module AutoMintSupport
  EMPTY_EDGE = %(Hecks.data_translation "Hecks", from: "5d288c", to: "f30dcb" do\nend\n).freeze
  FILLED_EDGE = %(Hecks.data_translation "Hecks", from: "5d288c", to: "f30dcb" do\n  drop "port"\nend\n).freeze
  NO_DIFF = { aggregates: [], retired: [], unclaimed: [] }.freeze
  BLUEBOOK = Struct.new(:aggregates).new([]).freeze

  Attr = Struct.new(:name, :optional) do
    def optional? = optional
  end
  Agg = Struct.new(:name, :attributes)

  # The shared decision's verdict for the held era, as the auto-mint rule reads it.
  def verdict(kind = "would_mint", reason: nil, source: "file")
    Hecks::Adapters::PostgresEra::LineageManager::MintDecision::Verdict.new(
      verdict: kind, reason: reason, edge: nil, edges: [], source: source, diff: NO_DIFF, watermark: 19
    )
  end

  # The verdict of a rename, which the decision refuses to take as additive.
  def held_by_rule = verdict("needs_edge", reason: :non_qualifying)

  def clean_facts(**overrides)
    { watermark: 19, from: "5d288c", to: "f30dcb", edge_text: EMPTY_EDGE, verdict: verdict,
      held: BLUEBOOK, current: BLUEBOOK }.merge(overrides)
  end

  def bluebook(*aggregates) = Struct.new(:aggregates).new(aggregates)

  def current_with_new_aggregate
    bluebook(Agg.new("ReleaseSample", [Attr.new("version", false)]))
  end

  def held_with_sample = bluebook(Agg.new("Sample", []))

  def current_with_sample_gaining_required = bluebook(Agg.new("Sample", [Attr.new("code", false)]))
end

RSpec.describe "the auto-mint rule" do
  include AutoMintSupport

  describe Hecks::Adapters::AutoMint do
    it "holds nothing for an empty additive edge with no refusals" do
      expect(described_class.held_reason(clean_facts, refusal_total: 0)).to be_nil
    end

    it "holds a mint whose edge declares a change" do
      expect(described_class.held_reason(clean_facts(edge_text: AutoMintSupport::FILLED_EDGE), refusal_total: 0))
        .to include("not empty")
    end

    it "holds a mint whose shape change is a rename" do
      expect(described_class.held_reason(clean_facts(verdict: held_by_rule), refusal_total: 0))
        .to include("not additive")
    end

    it "holds a mint whose rehearsal refused rows" do
      expect(described_class.held_reason(clean_facts, refusal_total: 2)).to include("refused 2 rows")
    end

    it "mints a new aggregate with required attributes on an empty edge" do
      expect(described_class.held_reason(clean_facts(current: current_with_new_aggregate), refusal_total: 0))
        .to be_nil
    end

    it "still holds a new aggregate's mint when the edge declares a change" do
      facts = clean_facts(current: current_with_new_aggregate, edge_text: AutoMintSupport::FILLED_EDGE)
      expect(described_class.held_reason(facts, refusal_total: 0)).to include("not empty")
    end

    it "holds a required attribute an existing aggregate gained" do
      facts = clean_facts(held: held_with_sample, current: current_with_sample_gaining_required, verdict: held_by_rule)
      expect(described_class.held_reason(facts, refusal_total: 0)).to include("not additive")
    end
  end
end
