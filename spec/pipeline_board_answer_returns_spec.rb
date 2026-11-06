# frozen_string_literal: true

require "spec_helper"
require_relative "support/answer_needs_node"

RSpec.describe "pipeline board answer controls: when they come back" do
  include AnswerNeedsNode

  it "shows again when the session asks a different question" do
    expect(run_node("a.note(ask('Q'), 'A', a.SENT); out.push(a.needsAnswer(ask('Another?')));")).to eq([true])
  end

  it "shows again when the session left blocked and came back" do
    steps = "a.note(ask('Q'), 'A', a.SENT); a.prune([ask('Q', 'busy')]); out.push(a.needsAnswer(ask('Q')));"
    expect(run_node(steps)).to eq([true])
  end

  it "keeps the reply for the You line while the control is hidden" do
    expect(run_node("a.note(ask('Q'), 'A', a.SENT); a.prune([ask('Q')]); out.push(a.reply('s1').text);")).to eq(["A"])
  end
end
