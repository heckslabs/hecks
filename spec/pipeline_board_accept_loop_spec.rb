# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# What the board's accept loop does when the process has no descriptor left to give: it sheds the
# connection, says so once, and goes on serving when descriptors free up.
RSpec.describe Hecks::Adapters::PipelineBoard::AcceptLoop do
  let(:logged) { [] }
  let(:served) { Queue.new }
  let(:time) { [0] }
  let(:limit) { instance_double(Hecks::Adapters::PipelineBoard::DescriptorLimit.singleton_class, raise!: nil) }

  # A listener that answers each accept with the next of its outcomes, then reports itself closed.
  let(:listener) do
    Class.new do
      def initialize(outcomes) = @outcomes = outcomes
      def wait_readable(_seconds) = self

      def accept_nonblock(exception: true)
        outcome = @outcomes.shift or raise IOError, "closed stream"
        outcome.is_a?(Class) ? raise(outcome) : outcome
      end
    end
  end

  def run_loop(*outcomes)
    accepting = described_class.new(listener.new(outcomes), pause: 0, clock: -> { time.first },
                                    log: ->(line) { logged << line }, limit: limit) { |socket| served << socket }
    accepting.start.join
  end

  it "serves the next connection after the descriptor table was full" do
    run_loop(Errno::EMFILE, :socket)
    expect(served.pop(timeout: 2)).to eq(:socket)
  end

  it "treats a full system table the same way" do
    run_loop(Errno::ENFILE, :socket)
    expect(served.pop(timeout: 2)).to eq(:socket)
  end

  it "logs a full table once however many accepts fail within the window" do
    run_loop(Errno::EMFILE, Errno::EMFILE, Errno::EMFILE)
    expect(logged.grep(/descriptor table full/).size).to eq(1)
  end

  it "ends when the listener is closed" do
    run_loop
    expect(served).to be_empty
  end
end
