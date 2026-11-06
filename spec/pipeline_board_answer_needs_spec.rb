# frozen_string_literal: true

require "spec_helper"
require_relative "support/answer_needs_node"

RSpec.describe "pipeline board answer controls: when they show" do
  include AnswerNeedsNode

  it "shows for a blocked session nobody has answered" do
    expect(run_node("out.push(a.needsAnswer(ask('Q')), a.needsAnswer(ask('Q', 'busy')));")).to eq([true, false])
  end

  it "hides once a reply is sending or sent" do
    steps = "a.note(ask('Q'), 'A', 'sending'); out.push(a.needsAnswer(ask('Q'))); " \
            "a.note(ask('Q'), 'A', a.SENT); out.push(a.needsAnswer(ask('Q')));"
    expect(run_node(steps)).to eq([false, false])
  end

  it "shows again when the send failed" do
    expect(run_node("a.note(ask('Q'), 'A', 'not sent: HTTP 500'); out.push(a.needsAnswer(ask('Q')));")).to eq([true])
  end

  it "has page.html and agents.html ask the helper" do
    expect(%w[page agents].map { |name| page_html(name).include?("boardAnswer.needsAnswer") }).to eq([true, true])
  end
end
