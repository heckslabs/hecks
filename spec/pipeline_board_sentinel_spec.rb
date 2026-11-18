# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
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
      def restart(misses: 0, reason: "stall") = @calls << [:restart, misses, reason]
    end
  end

  # A stand-in outside whose board always answers and spends the given CPU seconds per ask of 30s.
  let(:spinning) do
    Class.new(host) do
      def initialize(asks, spent)
        super(Array.new(asks, true))
        @spent = spent
        @cpu = @wall = 0.0
      end

      def cpu_seconds(_pid) = (@cpu += @spent.shift || 0)
      def clock = (@wall += 30)
    end
  end

  def watch(answers, misses: 3)
    outside = host.new(answers)
    [described_class.new(pid: 7, every: 30, misses: misses, host: outside).run, outside.calls]
  end

  it "restarts the board after misses unanswered asks in a row", :aggregate_failures do
    result, calls = watch([false, false, false, true])
    expect(result).to eq(:restarted)
    expect(calls.reject { |call| call.first == :pause }).to eq([[:stop, 7], [:restart, 3, "stall"]])
  end

  it "counts only asks in a row" do
    expect(watch([false, false, true, false, false, true]).first).to eq(:gone)
  end

  it "ends when the board is gone, restarting nothing", :aggregate_failures do
    result, calls = watch([])
    expect(result).to eq(:gone)
    expect(calls).to be_empty
  end

  def heated(spent, share: 0.9, asks: 3)
    outside = spinning.new(spent.length, spent)
    heat = described_class::Heat.new(share: share, asks: asks)
    [described_class.new(pid: 7, every: 30, misses: 3, host: outside, heat: heat).run, outside.calls]
  end

  it "restarts a board that answers but holds a core for asks in a row", :aggregate_failures do
    result, calls = heated([0, 29, 29, 29, 29])
    expect(result).to eq(:restarted)
    expect(calls.reject { |call| call.first == :pause }).to eq([[:stop, 7], [:restart, 3, "cpu"]])
  end

  it "counts only hot asks in a row" do
    expect(heated([0, 29, 29, 1, 29, 29, 1]).first).to eq(:gone)
  end

  it "never restarts on CPU when the share is 0" do
    expect(heated([0, 30, 30, 30, 30, 30], share: 0).first).to eq(:gone)
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

  describe described_class::Heat do
    it "ends a run of hot asks at an ask with no CPU reading" do
      heat = described_class.new(share: 0.5, asks: 2)
      expect([[0, 0], [20, 30], [nil, 60], [40, 90]].map { |cpu, wall| heat.hot?(cpu, wall) }).to all(be(false))
    end

    it "measures the share over the wall time between asks, not the period" do
      heat = described_class.new(share: 0.9, asks: 1)
      expect([[0, 0], [38, 40]].map { |cpu, wall| heat.hot?(cpu, wall) }).to eq([false, true])
    end
  end

  describe described_class::Host do
    {
      "12:34.56" => 754.56, "713:41.34" => 42_821.34, "1:02:03" => 3723.0, "2-01:00:00" => 176_400.0
    }.each do |text, seconds|
      it "reads the ps time #{text}" do
        expect(described_class.cpu_time("  #{text}\n")).to be_within(0.001).of(seconds)
      end
    end

    it "reads nothing from text that is not a time" do
      expect(described_class.cpu_time("")).to be_nil
    end

    it "reads no CPU time for a process that is gone" do
      host = described_class.new(pid: 0, port: 1, command: [], directory: Dir.pwd)
      expect(host.cpu_seconds(999_999)).to be_nil
    end
  end

  describe ".command" do
    # A bare interpreter, as the board spawns it: no bundler and no load path from the
    # environment, so the sentinel loads only through the load path its command names.
    let(:bare) { { "PATH" => ENV.fetch("PATH"), "HOME" => Dir.home } }

    it "starts a sentinel that loads and ends once its board is gone", :aggregate_failures do
      spec = { pid: 0, port: 1, command: [], directory: Dir.pwd, every: 0, misses: 1 }
      options = { unsetenv_others: true, chdir: Dir.tmpdir }
      _out, err, status = Open3.capture3(bare, *described_class.command(spec), **options)
      expect(err).not_to include("LoadError")
      expect(status).to be_success
    end
  end
end
