# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/sentinel/standing"

# The watch from outside the board restarts it after enough unanswered asks in a row.
RSpec.describe Hecks::Adapters::PipelineBoard::Sentinel do
  # A stand-in outside: answers from a list, then reports the board gone.
  let(:host) do
    Class.new do
      attr_reader :calls

      def initialize(answers)
        @answers = answers
        @calls = []
      end

      def parent_alive? = !@answers.empty?
      def pause(seconds) = @calls << [:pause, seconds]
      def answered? = @answers.shift
      def stop(pid) = @calls << [:stop, pid]
      def restart = @calls << [:restart]
    end
  end

  def watch(answers, misses: 3)
    outside = host.new(answers)
    [described_class.new(pid: 7, every: 30, misses: misses, host: outside).run, outside.calls]
  end

  it "restarts the board after misses unanswered asks in a row", :aggregate_failures do
    result, calls = watch([false, false, false, true])
    expect(result).to eq(:restarted)
    expect(calls.reject { |call| call.first == :pause }).to eq([[:stop, 7], [:restart]])
  end

  it "counts only asks in a row" do
    expect(watch([false, false, true, false, false, true]).first).to eq(:gone)
  end

  it "ends when the board is gone, restarting nothing", :aggregate_failures do
    result, calls = watch([])
    expect(result).to eq(:gone)
    expect(calls).to be_empty
  end

  it "waits the period between asks" do
    expect(watch([true]).last).to eq([[:pause, 30]])
  end

  describe ".stand" do
    it "starts nothing when the limits switch it off" do
      registry = instance_double(Hecks::Runtime::Registry, world: nil)
      allow(Hecks::Adapters::PipelineBoard::BoardRestart).to receive(:limits).and_return(sentinel_seconds: 0.0)
      expect(described_class.stand(port: 1, registry: registry)).to be_nil
    end

    it "starts nothing when one already stands for this environment" do
      allow(described_class).to receive(:standing?).and_return(true)
      expect(described_class.stand(port: 1)).to be_nil
    end
  end
end
