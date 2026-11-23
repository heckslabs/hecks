# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board's rest after a costly read: the next read is held for the read's cost over the duty.
RSpec.describe Hecks::Adapters::PipelineBoard::Snapshot do
  after { @snap&.stop }

  let(:now) { [0.0] }
  let(:held) { Queue.new }
  let(:wait) { ->(seconds) { (held << seconds) && Queue.new.pop } }
  let(:source) { -> { { generated_at: (now[0] += 25).to_s, stages: [] } } }

  def snapshot
    @snap = described_class.new(source: source, every: 0.01, read_duty: 0.1, clock: -> { now[0] }, wait: wait)
  end

  it "holds the next read for a costly read's cost over the duty" do
    snapshot.start
    expect(Timeout.timeout(5) { held.pop }).to be_within(1).of(250)
  end
end
