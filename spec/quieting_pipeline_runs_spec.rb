# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/quieting"

# A session the owner works in has no run, so a merge window never touches it. The sessions of live
# runs are stopped and the work they held goes back to the plan, its branch and commits kept.
RSpec.describe Hecks::Adapters::Quieting::PipelineRuns do
  let(:live) do
    { "a" => { status: "started", session: "s-a" }, "b" => { status: "retired", session: "s-b" },
      "c" => { status: "started", session: "" } }
  end
  let(:items) do
    held = %w[a b].map { |key| Struct.new(:key).new(key) }
    instance_double(Hecks::Adapters::Dispatching::WorkItems, runs: live, started: held)
  end
  let(:done) { { stopped: [], returned: [] } }
  let(:runs) do
    allow(Hecks::Adapters::Dispatching::WorkItems).to receive(:new).and_return(items)
    described_class.new(nil, stop:       ->(session) { done[:stopped] << session },
                             yield_back: ->(key) { done[:returned] << key })
  end

  it "knows the live runs that hold a session, and no others" do
    expect(runs.live).to eq("a" => "s-a")
  end

  it "stops those sessions and returns the items they held to the plan", :aggregate_failures do
    expect(runs.stop_all).to eq(sessions: ["s-a"], items: ["a"])
    expect(done).to eq(stopped: ["s-a"], returned: ["a"])
  end
end
