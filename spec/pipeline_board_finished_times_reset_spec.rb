# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require_relative "support/event_tail_world"

# What the held times do when the store they were read from changes or cannot be read.
RSpec.describe Hecks::Adapters::PipelineBoard::FinishedTimes do
  let(:log) { TailedLog.new }
  let(:host) { TimesHost.new(log) }

  before do
    log.add("WorkFinished", "t1")
    host.work_times
  end

  it "reads again from the start when the store is another one" do
    other = TailedLog.new.tap { |fresh| fresh.add("WorkFinished", "u1") }
    host.swap(other)
    expect(host.work_times[:finished]).to eq(["u1"])
  end

  it "reads again from the start when the log has shrunk" do
    log.add("WorkFinished", "t2")
    host.work_times
    log.events = [TailedLog::Event.new("WorkFinished", "n1")]
    expect(host.work_times[:finished]).to eq(["n1"])
  end

  %i[read count].each do |failure|
    it "keeps what it held when the #{failure} fails", :aggregate_failures do
      log.failing = failure
      expect { host.work_times }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable)
      log.failing = nil
      expect(host.work_times[:finished]).to eq(["t1"])
    end
  end
end
