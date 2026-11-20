# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The plan tile reads the reviews of work still open and no others: a review shows on its item's
# row, and the hundreds of finished items' transcripts are never parsed, which is what made the
# first drawing after a start slow.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanTile do
  let(:runs) do
    { "s1" => { agent: "architect", work_item: "open-one" }, "s2" => { agent: "architect", work_item: "done-one" },
      "s3" => { agent: "coder", work_item: "open-one" } }
  end
  let(:host) do
    held = runs
    Class.new do
      include Hecks::Adapters::PipelineBoard::PlanTile

      define_method(:initialize) do
        @tickets = Struct.new(:runs, :epics, :work_times) do
          def undone_work = [{ slug: "open-one", title: "T", status: "planned" }]
        end.new(held, [], {})
        @jobs = Struct.new(:rows).new([])
        @fill = Struct.new(:preview).new({ would_start: [], skipped: [] })
        @now = -> { Time.utc(2026, 11, 16, 12) }
        @root = "."
      end

      def guard = yield
      def train_tile = { name: "Train", state: "ok", count: "0", detail: "idle" }
    end.new
  end

  before { allow(Hecks::Adapters::PipelineBoard::AgentRoles).to receive(:reviews).and_return([]) }

  it "hands the reviews reader only the runs of open work items" do
    host.plan_tile
    expect(Hecks::Adapters::PipelineBoard::AgentRoles).to have_received(:reviews).with(hash_excluding("s2"))
  end

  it "keeps the runs of the open item" do
    host.plan_tile
    expect(Hecks::Adapters::PipelineBoard::AgentRoles).to have_received(:reviews).with(hash_including("s1"))
  end
end
