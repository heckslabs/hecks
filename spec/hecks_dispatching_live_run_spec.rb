require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A work item whose run is working is not started again, whatever its last yield said.
RSpec.describe Hecks::Adapters::Dispatching::Plan do
  let(:live) { { "a" => { status: "started", condition: "working" } } }

  def item(kind)
    described_class::Item.new(key: "a", title: "A", detail: "", area: [], yield_kind: kind, retry_at: "", yield_count: 1)
  end

  def plan(kind, runs) = described_class.new([item(kind)], [], cap: 5, load: 1.0, max_load: 9.0, frozen: [], runs: -> { runs })

  %w[transient already_recorded missing_passage].each do |kind|
    it "does not choose a #{kind}-yielded item whose run is started", :aggregate_failures do
      expect(plan(kind, live).chosen).to be_empty
      expect(plan(kind, live).skipped.first.reason).to start_with("parked: run a is started")
    end
  end

  it "chooses an item whose run has ended" do
    ended = { "a" => { status: "finished", condition: "done" } }

    expect(plan("", ended).chosen.map(&:key)).to eq(["a"])
  end
end
