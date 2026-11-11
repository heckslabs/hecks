# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The board's headline is computed from the classed sessions and the last fill report, so every
# number in it means one thing. The sessions and the open Work items here are stand-ins for the
# Claude listing and the ledger.
RSpec.describe Hecks::Adapters::PipelineBoard::Headline do
  let(:root) { "/work/hecks" }
  let(:open_work) { %w[run-a run-b run-c held-a held-b held-c].map { |slug| { slug: slug, status: "started", title: slug } } }
  let(:fill) { { load: 5.3, limit: 10.0, cap: 6, started: 3, would_start: [], skipped: [] } }

  def session(status, item, extra = {})
    { id: item, name: item, status: status, run: "r-#{item}", work_item: item, detail: "", cwd: "#{root}/wt/#{item}",
      context: { said: "tests are running" } }.merge(extra)
  end

  def sentence(list, report = fill)
    marked = Hecks::Adapters::PipelineBoard::OwnerQueue.mark(list, open_work, root)
    described_class.sentence(marked, report)
  end

  def the_2026_11_11_listing
    running = %w[run-a run-b run-c].map { |item| session("busy", item) }
    held = [session("blocked", "held-a"), session("blocked", "held-b", context: { said: "[review] x" }),
            session("blocked", "held-c")]
    leftovers = %w[gone-a gone-b gone-c].map { |item| session("busy", item) }
    running + held + leftovers + [session("blocked", "", run: "", cwd: "/work/emaho")]
  end

  it "states the 2026-11-11 15:27Z listing as it was", :aggregate_failures do
    text = sentence(the_2026_11_11_listing)
    expect(text).to start_with("3 sessions running (cap 6 items), 3 waiting on a review or the coordinator, ")
    expect(text).to include("3 finished and waiting to be removed; load 5.3 of 10.0")
    expect(text).not_to match(/waiting on you|at the cap/)
  end

  it "counts one explicit question to the owner as waiting on you" do
    list = [session("blocked", "held-a", context: { said: "[owner] which account?" })]
    expect(sentence(list)).to include("1 waiting on you")
  end

  it "classes a busy session whose Work item finished as a leftover" do
    expect(sentence([session("busy", "gone-a")])).to include("1 finished and waiting to be removed")
  end

  it "leaves a session of another repository out of every count" do
    expect(sentence([session("busy", "", run: "", cwd: "/work/emaho")])).to start_with("no sessions running")
  end

  it "names the fill's own reason when it can start nothing", :aggregate_failures do
    refused = fill.merge(skipped: [{ slug: "x", reason: "cap 6 reached" }])
    expect(sentence([], refused)).to end_with("the fill can start more: no because cap 6 reached")
    expect(sentence([], fill)).to end_with("the fill can start more: no because nothing planned")
  end

  it "says the fill can start more when it would start an item" do
    planned = fill.merge(would_start: [{ slug: "x", title: "t" }])
    expect(sentence([], planned)).to end_with("the fill can start more: yes")
  end

  it "says load when the load is at its limit" do
    expect(sentence([], fill.merge(load: 10.0))).to end_with("no because load")
  end
end
