# frozen_string_literal: true

require "spec_helper"
require "benchmark"
require_relative "support/fake_journal"
require_relative "support/plan_page_speed_kit"
require "hecks/pipeline_board/adapters/pipeline_web"

# The planning page answers from what the board already holds: a request launches no process, a
# run of requests reads the plan once, and 300 Work items draw in well under a second.
RSpec.describe "the planning page's speed" do
  include PlanPageSpeedKit

  let(:reads) { [] }
  let(:stages) do
    counted = reads
    instance_double(Hecks::Adapters::PipelineStages, state: { stages: [] }, **FakeJournal::TILES).tap do |fake|
      allow(fake).to receive(:plan_tile) { (counted << :plan_tile) && { unknown: "none" } }
    end
  end
  let(:web) { Hecks::Adapters::PipelineWeb.new(settings: { stages: stages, background: false, journal: FakeJournal.source }) }

  after { web.close }

  it "reads the plan once for a run of requests" do
    20.times { web.plan_page }
    expect(reads.size).to eq(1)
  end

  it "launches no process to answer a request" do
    refuse_processes
    expect { 5.times { web.plan_page } }.not_to raise_error
  end

  it "draws 300 Work items in under one second" do
    expect(Benchmark.realtime { Hecks::Adapters::PipelineBoard::PlanHtml.draw(reading(300)) }).to be < 1
  end
end
