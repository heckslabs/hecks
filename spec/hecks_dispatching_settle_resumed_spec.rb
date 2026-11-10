require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A run an answer resumed after the session listing is working again: its Work item is not yielded.
RSpec.describe Hecks::Adapters::Dispatching::Settler do
  let(:dispatching) { Hecks::Adapters::Dispatching }
  let(:launcher) { instance_double(dispatching::Launcher, check_all: nil, finish: "f", yield_back: "y") }
  let(:items) { instance_double(dispatching::WorkItems, started: [entry]) }

  def entry = dispatching::Plan::Item.new(key: "a", title: "A", detail: "", area: [])

  def run(status, condition) = { "a" => { status: status, condition: condition } }

  it "does not yield the work item once an answer resumed the run", :aggregate_failures do
    stale = run("finished", "stopped")
    allow(items).to receive(:runs).and_return(stale, stale, run("started", "working"))

    expect(described_class.new(items, launcher).call).to eq([])
    expect(launcher).not_to have_received(:yield_back)
  end
end
