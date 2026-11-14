require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/ticking"

# The chain on a clock of its own: each wait is recorded and advances the time, each tick is a
# refusal-free dispatch, and the watcher is a stand-in.
module TickingScheduleHelpers
  Clock = Struct.new(:time, :naps) do
    def now = time

    def nap(seconds)
      naps << seconds
      self.time += seconds
    end
  end

  Out = Struct.new(:ticks, :stops) do
    def note(_line) = nil

    def tick(count)
      ticks << count
      nil
    end

    def stop(why) = stops << why
  end

  # A watcher that runs until `exit_after` polls have passed (never when nil).
  class Watching
    attr_reader :starts, :state

    def initialize(exit_after: nil)
      @exit_after = exit_after
      @state = :idle
      @starts = 0
      @polls = 0
    end

    def start
      @starts += 1
      @state = :running
    end

    def poll
      @polls += 1
      @state = :done if @exit_after && @polls >= @exit_after
      @state
    end

    def stop = nil
  end

  def chain(watcher: nil, minutes: 10)
    backoff = Hecks::Adapters::Ticking::Backoff.new(quick: 20)
    Hecks::Adapters::Ticking::Chain.new(out, backoff, minutes, watcher, clock)
  end
end

RSpec.describe Hecks::Adapters::Ticking::Chain do
  include TickingScheduleHelpers

  let(:clock) { TickingScheduleHelpers::Clock.new(0.0, []) }
  let(:out) { TickingScheduleHelpers::Out.new([], []) }

  it "waits quick, then 60, 120 and 240 seconds", :aggregate_failures do
    chain.run
    expect(clock.naps.first(6)).to eq([20.0, 20.0, 20.0, 60.0, 120.0, 240.0])
    expect(out.stops.first).to start_with("the chain outlived its 10 minutes")
  end

  it "starts one watcher and ticks only at the cap while it runs", :aggregate_failures do
    watcher = TickingScheduleHelpers::Watching.new
    chain(watcher: watcher).run
    expect(watcher.starts).to eq(1)
    expect(out.ticks).to eq([1, 2, 3, 4, 5])
  end

  it "ticks at once when the watcher exits, then goes on by the ladder", :aggregate_failures do
    watcher = TickingScheduleHelpers::Watching.new(exit_after: 3)
    chain(watcher: watcher).run
    expect(clock.naps.drop(3).first(5)).to eq([1, 1, 1, 60.0, 120.0])
  end

  it "ticks again after a watcher fails, on the ladder" do
    watcher = instance_double(Hecks::Adapters::Ticking::Watcher, start: nil, stop: nil, state: :failed)
    chain(watcher: watcher).run
    expect(clock.naps[3]).to eq(60.0)
  end
end
