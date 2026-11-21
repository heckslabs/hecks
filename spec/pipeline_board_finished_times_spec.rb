# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require_relative "support/event_tail_world"

# The board folds the Work events it has not seen, and reads none again.
RSpec.describe Hecks::Adapters::PipelineBoard::FinishedTimes do
  let(:log) { TailedLog.new }
  let(:host) { TimesHost.new(log) }

  before do
    log.add("WorkPlanned", "t1")
    log.add("AgentCheckRequested", "t2")
    log.add("WorkFinished", "t3")
  end

  it "reads the whole log at the start" do
    expect(host.work_times).to include(planned: ["t1"], finished: ["t3"], dropped: [])
  end

  it "reads none on a second refresh with no new events" do
    2.times { host.work_times }
    expect(log.asked).to eq([0, 3])
  end

  it "reads only the n new events and keeps the times it held" do
    host.work_times
    log.add("WorkDropped", "t4")
    log.add("WorkFinished", "t5")
    expect(host.work_times).to include(finished: %w[t3 t5], dropped: ["t4"], planned: ["t1"])
  end

  it "asks for the new events from where it stopped" do
    host.work_times
    log.add("WorkDropped", "t4")
    host.work_times
    expect(log.asked).to eq([0, 3])
  end

  it "counts one new event once when two threads refresh together" do
    host.work_times
    log.add("WorkFinished", "t4")
    Array.new(2) { Thread.new { host.work_times } }.each(&:join)
    expect(host.work_times[:finished]).to eq(%w[t3 t4])
  end

  it "answers frozen times that a caller cannot grow" do
    expect(host.work_times[:finished]).to be_frozen
  end
end
