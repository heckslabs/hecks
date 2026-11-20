# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require_relative "support/board_rows"

# The rows the board's own adapters answer are the shape the bluebook declares: what the readers
# give for the queries is built as the value objects, as the runtime builds it. Every reader but
# Tickets and Jobs is one that cannot answer, so each of its readings is a row in state `unknown`.
RSpec.describe Hecks::Adapters::PipelineBoard::TypedAnswers do
  include PipelineBoardWorld
  include BoardRows

  scratch_directory :dir, "typed-answers"

  let(:tickets) { Hecks::Adapters::PipelineTickets.new(settings: { work_items: work_items, landings: [] }) }
  let(:jobs) { Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: @dir, runs: -> { {} }, now: -> { Time.now } }) }
  let(:stages) { silent_board(@dir, tickets: tickets, jobs: jobs) }

  before { job_dir(@dir, "s1", "working", "building") }

  it "answers a board the bluebook accepts as a Snapshot, a reader that failed as unknown rows" do
    states = built("Snapshot", stages.board)[:stages].to_h { |stage| [stage[:key], stage[:state]] }
    expect(states).to include("work_items" => "working", "sessions" => "working", "ci" => "unknown", "train" => "unknown")
  end

  it "answers the sessions as SessionLine rows" do
    expect(built("SessionLine", jobs.sessions.first)).to include(id: "s1", status: "busy", ended: "", work_item: "")
  end

  it "answers the open Work items as WorkLine rows" do
    expect(tickets.open_work.map { |row| built("WorkLine", row)[:slug] }).to eq(%w[a b])
  end

  it "refuses the cycles with the reason when the stage events could not be read" do
    expect { stages.cycles }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /NoMethodError/)
  end
end
