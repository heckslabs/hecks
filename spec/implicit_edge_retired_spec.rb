require "hecks"
require "hecks/ports/persistence/plugins/era/translation/implicit_edge"

# An implicit edge answers every question a rehearsal or an export asks of a written edge, and
# answers each as an edge that changes nothing.
RSpec.describe Hecks::Translation::ImplicitEdge do
  subject(:edge) { described_class.new(domain: "Ledger", from: "aaaaaa", to: "bbbbbb") }

  it "retires no aggregate" do
    expect(edge.retired).to eq([])
  end

  it "declares no aggregate rule" do
    expect([edge.aggregates, edge.for_aggregate("Acct")]).to eq([[], nil])
  end
end
