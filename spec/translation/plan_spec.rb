require "spec_helper"
require "json"

# A translation as plan data: every rule list has an op, in the order the rules apply.
RSpec.describe Hecks::Bluebook::TranslationPlan do
  def declared(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks.data_translation("Ledger", from: "aaaaaa", to: "bbbbbb", &block) }
    registry.translations.first
  end

  def ledger_edge
    declared do
      aggregate "Account", was: "Acct" do
        backfill :tier, default: "standard"
        drop :legacy
        rename :cost, to: :amount
        derive :label, as: "upper(code)"
        convert "kind", to: "tier", values: { "biz" => "business" }
      end
      retired "Gone"
    end
  end

  let(:plan) { ledger_edge.to_plan }
  let(:ops) { plan["aggregates"].first["ops"] }

  it "names the edge and its aggregates" do
    expect(plan).to include("version" => 1, "domain" => "Ledger", "from" => "aaaaaa", "to" => "bbbbbb")
  end

  it "lists the ops in the order the rules apply, whatever order they were declared in" do
    expect(ops.map { |op| op["op"] }).to eq(%w[derive rename convert drop backfill])
  end

  it "carries a derive's expression as its parsed tree" do
    expect(ops.first).to eq("op" => "derive", "to" => "label", "expression" => ["upper", ["ref", "code"]])
  end

  it "survives a round trip through JSON" do
    expect(JSON.parse(JSON.generate(plan))).to eq(plan)
  end

  it "has an op for every rule list a TranslationAggregate holds" do
    lists = Hecks::Bluebook::TranslationAggregate::FIELD_DEFAULTS.keys - [:was]
    renamed = { "backfill" => "backfills", "rekey_to" => "rekeys" }
    expect(described_class::OPS.map { |op| renamed.fetch(op, "#{op}s") }).to match_array(lists.map(&:to_s))
  end
end
