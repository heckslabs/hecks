# frozen_string_literal: true

require_relative "../support/session_line_words"

# A run that names no agent but works as a role with a role file starts as that role.
RSpec.describe Hecks::Adapters::SessionLine do
  include SessionLineWords

  let(:checkout) { McpSelectionCheckout.build }

  after { FileUtils.remove_entry(checkout) }

  it "starts a fill-started coder as coder, whose role file declares the model" do
    expect(role_of(words(works_as: "coder"))).to eq("coder")
  end

  it "treats a blank agent as none" do
    expect(role_of(words(works_as: "coder", agent: { value: nil }))).to eq("coder")
  end

  it "keeps an explicit agent over works_as" do
    expect(role_of(words(works_as: "coder", agent: "architect"))).to eq("architect")
  end

  it "adds no agent for a works_as with no role file" do
    expect(words(works_as: "answerer")).not_to include("--agent")
  end

  it "never reads a role file outside .claude/agents" do
    expect(words(works_as: "../x")).not_to include("--agent")
  end
end
