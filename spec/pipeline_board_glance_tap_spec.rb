# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require "hecks/runtime/event_log"
require_relative "support/glance_facts"
require_relative "support/typed_board_boot"

# Each read of the `Glance` reaches the event tap as one `GlanceRead` line, so the reads can be
# counted, and the typed query is refused when an adapter answers a row of another shape.
RSpec.describe Hecks::Adapters::PipelineBoard::TypedAnswers, "#glance" do
  include GlanceFacts
  include TypedBoardBoot

  scratch_directory :dir, "glance-tap"

  let(:log)  { Hecks::Runtime::EventLog.new }
  let(:seen) { [] }
  let(:board) { glance_host(Struct.new(:event_log).new(log)) }

  before { log.observer = ->(event) { seen << event.name } }

  it "appends one GlanceRead to the event log for each read" do
    3.times { board.glance }
    expect(seen).to eq(%w[GlanceRead] * 3)
  end

  it "answers the glance whether or not a log is there" do
    expect(glance_host(nil).glance).to eq(entries: [], flowing: {})
  end

  it "builds the answer of the Pipeline port as a Glance through the booted board" do
    flow = { admission: "open", next_start: [], train_state: "idle" }
    answer = ask_typed_board(@dir, "Glance", { entries: [], flowing: flow })
    expect(answer.first[:flowing]).to include(admission: "open", admission_why: "", train_why: "")
  end

  it "refuses an answer whose entry has a field a StuckItem does not declare" do
    answer = { entries: [{ kind: "owner_ask", what: "x", colour: "red" }], flowing: { admission: "open", train_state: "idle" } }
    expect { ask_typed_board(@dir, "Glance", answer) }.to raise_error(Hecks::Runtime::UnknownArgument, /Glance/)
  end
end
