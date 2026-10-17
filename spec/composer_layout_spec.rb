require "spec_helper"
require "hecks/composer/layout"

# The layout proposal is a plain rule set over the author's intent and the check's verdict.
RSpec.describe Hecks::Composer::Layout do
  def propose(intent, check = {})
    described_class.propose(intent: intent, check: check, changed: {})
  end

  def refusal = { diagnostic: { file: "a.bluebook", line: 1, message: "no", expected: [] } }

  it "always puts the agent at the bottom", :aggregate_failures do
    expect(propose("edit")[:bottom]).to eq("agent")
    expect(propose("question", refusal)[:bottom]).to eq("agent")
  end

  it "shows the diagram for an edit or a new domain", :aggregate_failures do
    expect(propose("edit")[:right]).to eq("diagram")
    expect(propose("new_domain")[:right]).to eq("diagram")
  end

  it "shows the wiring for a wire request" do
    expect(propose("wire")[:right]).to eq("wiring")
  end

  it "shows the statements for a question" do
    expect(propose("question")[:right]).to eq("statements")
  end

  it "shows the findings when the check refused", :aggregate_failures do
    expect(propose("edit", refusal)[:right]).to eq("findings")
    expect(propose("wire", refusal)[:right]).to eq("findings")
  end

  it "shows the findings for an error finding of either spelling", :aggregate_failures do
    expect(propose("edit", { findings: [{ severity: :error }] })[:right]).to eq("findings")
    expect(propose("question", { findings: [{ severity: "error" }] })[:right]).to eq("findings")
  end

  it "ignores warnings" do
    expect(propose("edit", { diagnostic: nil, findings: [{ severity: :warning }] })[:right]).to eq("diagram")
  end
end
