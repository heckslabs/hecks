require_relative "mint_decision_spec"

# An era a first hold left unnamed has no stored label; the decision names it by its shape.
RSpec.describe "the mint decision over an era held before it was named" do
  include MintDecisionSupport

  let(:unnamed) { MintDecisionSupport::Decision.held_for_decision(held_era(ledger_text).merge(label: nil, hash: nil)) }
  let(:edge) do
    Struct.new(:domain, :from, :to).new("Ledger", MintDecisionSupport::Decision.held_label_of(unnamed), label_of(renamed_current))
  end

  def decide_from(current, edges)
    MintDecisionSupport::Decision.decide(held: [unnamed], bluebook: declared(current),
                                         edge_source: { translations: edges }, watermark: 1, rows: [])
  end

  it "leads on the edge written from the era's shape, as a named era does", :aggregate_failures do
    verdict = decide_from(renamed_current, [edge])

    expect([verdict.verdict, verdict.source]).to eq(%w[would_mint file])
  end

  it "implicitly mints an additive move from it, the edge naming the era's shape" do
    expect(decide_from(optional_current, []).edge.from).to eq(MintDecisionSupport::Decision.held_label_of(unnamed))
  end
end
