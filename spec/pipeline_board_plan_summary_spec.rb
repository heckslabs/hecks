# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"

RSpec.describe Hecks::Adapters::PipelineBoard::PlanSummary do
  subject(:held) { described_class.new }

  def event(name, work, **payload)
    Hecks::Runtime::Event.new(name: name, aggregate: "Work", id: work, payload: payload.merge(work: work))
  end

  let(:events) do
    [event("WorkPlanned", "a", epic: "e1"), event("WorkPlanned", "b", epic: "e1"), event("WorkPlanned", "c"),
     event("WorkPrioritized", "a", priority: "now"), event("WorkStarted", "b"), event("WorkFinished", "c"),
     event("WorkAssigned", "c", epic: "e2"), event("WorkFinished", "a")]
  end
  let(:epics) { [Hecks::Runtime::Event.new(name: "EpicOpened", id: "e1", payload: { epic: "e1", title: "Zed" })] }

  it "keeps counts per lane and the done total", :aggregate_failures do
    summary = held.catch_up(:work, events).summary
    expect(summary).to include(done: 2, open: 1)
    expect(summary[:lanes]).to include("unset" => 1, "now" => 0, "done" => 2)
  end

  it "counts an expedited item in the expedite lane" do
    expedited = events + [event("WorkPlanned", "d"), event("WorkExpedited", "d", priority: "expedite")]

    expect(held.catch_up(:work, expedited).summary[:lanes]).to include("expedite" => 1, "unset" => 1)
  end

  it "moves a running item to the running lane" do
    expect(held.catch_up(:work, events).summary(running: ["b"])[:lanes]).to include("running" => 1, "unset" => 0)
  end

  it "applies only the events past its cursor" do
    held.catch_up(:work, events.first(2))
    expect(held.catch_up(:work, events).summary[:done]).to eq(2)
  end

  it "starts again when the source shrinks" do
    held.catch_up(:work, events)
    expect(held.catch_up(:work, events.first(1)).summary[:open]).to eq(1)
  end

  it "names the first epics by title" do
    held.catch_up(:work, events).catch_up(:epic, epics)
    expect(held.first_epics(3)).to eq([{ epic: "e1", title: "Zed", open: 1, done: 1 }])
  end

  describe "the plan tile's draw" do
    let(:reader) do
      held_events = events
      Class.new do
        define_method(:plan_events) { { work: held_events, epic: [] } }
        def undone_work = raise("a draw scanned the Work items")
      end.new
    end
    let(:tile) do
      host = Class.new { include Hecks::Adapters::PipelineBoard::PlanTile }.new
      host.instance_variable_set(:@tickets, reader)
      host.define_singleton_method(:guard) { |&block| block.call }
      host
    end

    it "answers the summary without reading a Work item", :aggregate_failures do
      expect(tile.plan_summary).to include(done: 2, open: 1)
      expect(tile.plan_summary(running: ["b"])[:lanes]).to include("running" => 1)
    end

    it "answers nil when the reader offers no plan events" do
      tile.instance_variable_set(:@tickets, Object.new)
      expect(tile.plan_summary).to be_nil
    end
  end
end
