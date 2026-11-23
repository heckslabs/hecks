# frozen_string_literal: true

require "spec_helper"
require_relative "support/registry_double"
require "hecks/tickets/bluebook/adapters/work_spend"

# The WorkSpend port's adapter against stand-in runs: the pomodoros a finished item's runs spent,
# from each run's start to its SessionFinished, 25 minutes a round, rounded up.
RSpec.describe Hecks::Adapters::WorkSpend do
  include RegistryDouble

  Moment = Struct.new(:name, :id, :occurred_at)

  def run(key, started, work: "")
    { run: key, work: work, started_at: started, id: key }
  end

  def registry_of(runs, finishes)
    registry = registry_double
    bluebook = Struct.new(:aggregates).new([Struct.new(:hecks_name).new("AgentRun")])
    allow(registry).to receive_messages(bluebook: bluebook, event_log: finishes)
    allow(registry).to receive(:repository).and_return(Struct.new(:all).new(runs))
    registry
  end

  def spend(runs, finishes, key = "item")
    described_class.new(registry: registry_of(runs, finishes)).read_spend(work: { value: key })[:pomodoros_spent][:value]
  end

  let(:done) { ->(key, at) { Moment.new("SessionFinished", key, at) } }

  it "rounds one run of fifty-one minutes up to three pomodoros" do
    expect(spend([run("item", "2026-11-23T10:00:00Z")], [done.call("item", "2026-11-23T10:51:00Z")])).to eq(3)
  end

  it "sums the runs of an item after a yield before it rounds" do
    runs = [run("a", "2026-11-23T10:00:00Z", work: "item"), run("b", "2026-11-23T12:00:00Z", work: "item")]
    ends = [done.call("a", "2026-11-23T10:30:00Z"), done.call("b", "2026-11-23T12:30:00Z")]
    expect(spend(runs, ends)).to eq(3)
  end

  it "spends none when no run is the item's" do
    expect(spend([], [])).to eq(0)
  end

  it "never borrows a run that names another item" do
    runs = [run("item", "2026-11-23T10:00:00Z", work: "other")]
    expect(spend(runs, [done.call("item", "2026-11-23T11:00:00Z")])).to eq(0)
  end

  it "counts a run still going for nothing" do
    expect(spend([run("item", "2026-11-23T10:00:00Z")], [])).to eq(0)
  end
end
