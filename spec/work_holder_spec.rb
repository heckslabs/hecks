require "spec_helper"
require "hecks/hecks/adapters/work_holder"

# What a dispatch is told about another run on the same work: facts only, so the bluebook decides.
RSpec.describe Hecks::Adapters::WorkHolder do
  # Plain locals, not constants: a constant assigned here lands on Object for every later spec.
  let(:records) { [] }
  let(:registry) do
    book = Struct.new(:aggregates).new([Struct.new(:hecks_name).new("AgentRun")])
    repository = Struct.new(:all).new(records)
    Struct.new(:book, :repository) do
      def bluebook(_domain) = book

      def repository(*) = self[:repository]
    end.new(book, repository)
  end
  let(:holder) { described_class.new(registry) }

  def run(key, status: "started", work: nil, agent: nil)
    { run: { value: key }, status: status, work: work && { value: work }, agent: agent && { value: agent } }
  end

  def ask(key, **fields) = holder.call(run(key, **fields))

  it "names a started run keyed by the work the dispatch names", :aggregate_failures do
    records << run("item-a")
    answer = ask("other", work: "item-a")
    expect(answer).to include(holder: "item-a", holder_status: "started", holder_agent: "")
  end

  it "names a started run that names the same work slug under another key" do
    records << run("first", work: "item-a")
    expect(ask("second", work: "item-a")).to include(holder: "first")
  end

  it "says nothing when only its own record serves the work" do
    records << run("item-a")
    expect(ask("item-a")).to include(holder: "")
  end

  it "reports a held run's agent and the dispatched run's own agent", :aggregate_failures do
    records << run("review-1", work: "item-a", agent: "architect")
    answer = ask("item-a", agent: "coder")
    expect(answer).to include(holder: "review-1", holder_agent: "architect", requester_agent: "coder")
  end

  it "prefers a started run to an ended one on the same work" do
    records.push(run("old", status: "finished", work: "item-a"), run("new", work: "item-a"))
    expect(ask("third", work: "item-a")).to include(holder: "new")
  end

  it "reads no runs without a registry" do
    expect(described_class.new(nil).call(run("x"))).to include(holder: "")
  end
end
