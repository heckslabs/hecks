# frozen_string_literal: true

require "spec_helper"
require "hecks/roundhouse/adapters/metering"

# The role Roundhouse's meter counts a session under: a run's agent, else the part it works as, so a
# fill's coder (dispatched with no agent, as `works_as: coder`) counts as a coder.
RSpec.describe Hecks::Adapters::Metering::SessionRole do
  def role(run, entry = { "kind" => "background", "name" => "some-session" }) = described_class.of(entry, run)

  it "counts a run dispatched with no agent by the part it works as" do
    expect(role({ agent: "", works_as: "coder" })).to eq("coder")
  end

  it "counts a run whose agent is coder as a coder" do
    expect(role({ agent: "coder", works_as: "" })).to eq("coder")
  end

  it "keeps an orchestrator dispatched under another part an orchestrator" do
    expect(role({ agent: "orchestrator", works_as: "red-wake" })).to eq("orchestrator")
  end

  it "counts any other agent as a helper" do
    expect(role({ agent: "reviewer", works_as: nil })).to eq("helper")
  end

  it "counts an unrun interactive session as the person's own" do
    expect(role(nil, { "kind" => "interactive", "name" => "miette" })).to eq("person")
  end
end
