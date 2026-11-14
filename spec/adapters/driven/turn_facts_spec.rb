require "spec_helper"
require "hecks/hecks/adapters/turn_facts"

# What the TurnFacts port measures of a run ending a turn, over a stand-in registry: the part the
# run plays, whether its Work item is still started, whether its branch landed, whether it waits on
# a review, and the question and last word of its closing message. It judges none of them.
RSpec.describe Hecks::Adapters::TurnFacts do
  let(:run) { { run: "fix-it", status: "started", works_as: "coder", session: "abc123", repo: "/tmp/fix-it" } }
  let(:work) { { work: "fix-it", status: "started" } }
  let(:message) { "All specs pass.\n\nI am done." }

  def book(name) = double(aggregates: [double(hecks_name: name)])

  def registry(runs, items)
    stores = { "Hecks" => runs, "Tickets" => items }
    instance_double(Hecks::Runtime::Registry).tap do |held|
      allow(held).to receive(:bluebook) { |domain| book(domain == "Hecks" ? "AgentRun" : "Work") }
      allow(held).to receive(:repository) { |domain, _| double(all: stores.fetch(domain)) }
    end
  end

  def facts(runs: [run], items: [work], landed: nil, transcript: message, tail: "")
    described_class.new(registry: registry(runs, items), landed: ->(_work, _repo) { landed },
                        closing: double(of: transcript), jobs: double(closing: tail))
                   .measure_turn(run: { value: "fix-it" }, again: { value: false })
  end

  it "measures a coder that said done and handed nothing in" do
    expect(facts).to eq(role: "coder", reviewing: false, held: true, landed: false, question: "", word: "done", again: false)
  end

  it "reads the Work item as not held once it is no longer started" do
    expect(facts(items: [work.merge(status: "done")])).to include(held: false)
  end

  it "reads a landing since the item started" do
    expect(facts(landed: "0a1b2c3d4")).to include(landed: true)
  end

  it "reads the Work item a run names when its key is not the item's own" do
    expect(facts(runs: [run.merge(work: "other")])).to include(held: false)
  end

  it "reads the agent as the role of a run that plays no part" do
    expect(facts(runs: [run.merge(works_as: nil, agent: "architect")])).to include(role: "architect")
  end

  it "reads an open plan review" do
    expect(facts(runs: [run.merge(reviewing: true)])).to include(reviewing: true)
  end

  it "reads the first bracketed line of the closing message as the question" do
    expect(facts(transcript: "Plan sent.\n\n[review] Is the plan sound?")).to include(question: "[review] Is the plan sound?")
  end

  it "reads the last word without its punctuation or markup" do
    expect(facts(transcript: "Branch fix-it at 0a1b2c3.\n\n**submitted**.")).to include(word: "submitted")
  end

  it "falls back to the tail the job keeps when the transcript holds no message" do
    expect(facts(transcript: "", tail: "could not finish: blocked")).to include(word: "blocked")
  end

  it "passes on that the turn is ending again" do
    adapter = described_class.new(registry: registry([run], [work]), landed: ->(*) {}, closing: double(of: message))

    expect(adapter.measure_turn(run: "fix-it", again: true)).to include(again: true)
  end

  it "refuses a run that is not started" do
    expect { facts(runs: [run.merge(status: "finished")]) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "no started run is named fix-it")
  end
end
