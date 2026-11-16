# frozen_string_literal: true

require "spec_helper"
require "open3"
require "timeout"
require "hecks/pipeline_board/adapters/pipeline_journal/watch"

# Helpers that read the state of a process the example itself started, so another example's
# children never count.
module WatchReapedHelpers
  # The source a follower reads: the process's lines, and a `closed` queue fed once it is closed.
  class ClosingSource
    # @return [Queue] receives `:closed` once {#close} has waited for the process
    attr_reader :closed

    # @param io [IO] the followed process
    def initialize(io)
      @io = io
      @closed = Queue.new
    end

    # @return [String, nil] the next line
    def gets = @io.gets

    # @return [Integer] the followed process's pid, so a stop can end it
    def pid = @io.pid

    # Waits for the process to end, then says so.
    def close
      @io.close
      @closed << :closed
    end
  end

  # Follows the process and waits until the follower has closed it.
  # @return [Integer] the process's pid
  def followed_until_closed(io)
    pid = io.pid
    source = ClosingSource.new(io)
    Hecks::Adapters::PipelineBoard::Watch.new(path: "x", source: -> { source }).start { nil }
    Timeout.timeout(5) { source.closed.pop }
    pid
  end

  # @return [String] the process's `ps` state, empty when it is gone, `Z` when defunct
  def state_of(pid) = Open3.capture2("ps", "-o", "stat=", "-p", pid.to_s).first.strip

  # A followed process that writes one line, then stays until it is stopped.
  # @return [IO] the process, its pid on `pid`
  def talker = IO.popen(["sh", "-c", "echo '{}'; sleep 30"])

  # Starts one follower twice, over two processes.
  # @return [Array<Integer>] the pids of the two processes, in the order they were started
  def started_twice
    sources = [IO.popen(["sleep", "30"]), IO.popen(["sleep", "30"])]
    watch = Hecks::Adapters::PipelineBoard::Watch.new(path: "x", source: -> { sources.shift })
    pids = sources.map(&:pid)
    2.times { watch.start { nil } }
    watch.stop
    pids
  end

  # Follows a process that writes a line to a block that raises, and waits for the follower's end.
  # @return [Integer] the process's pid
  def followed_by_a_raising_block
    io = talker
    pid = io.pid
    source = ClosingSource.new(io)
    Hecks::Adapters::PipelineBoard::Watch.new(path: "x", source: -> { source }).start { raise "boom" }
    Timeout.timeout(5) { source.closed.pop }
    pid
  end

  # @return [String] the process's state once it is gone, or what it stays in after five seconds
  def settled_state(pid)
    300.times { return "" if state_of(pid).empty? }
    state_of(pid)
  end
end

# The journal follower waits on the process it follows, so none is left defunct, whether the
# process ended on its own or the follower was stopped.
RSpec.describe Hecks::Adapters::PipelineBoard::Watch do
  include WatchReapedHelpers

  it "reaps a followed process that ended on its own, without a stop" do
    pid = followed_until_closed(IO.popen(["true"]))
    expect(state_of(pid)).to eq("")
  end

  it "reaps a followed process that stop ended" do
    io = IO.popen(["sleep", "30"])
    pid = io.pid
    described_class.new(path: "x", source: -> { io }).start { nil }.stop
    expect(state_of(pid)).to eq("")
  end

  it "reaps the process of a follower that was started again", :aggregate_failures do
    pids = started_twice
    expect(pids.map { |pid| settled_state(pid) }).to eq(["", ""])
  end

  it "reaps a followed process when the block that takes its lines raises" do
    expect(settled_state(followed_by_a_raising_block)).to eq("")
  end
end
