# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_github"

# The growth of the hold across consecutive failures of one job.
RSpec.describe Hecks::Adapters::PipelineBoard::LogBackoff do
  let(:now) { [0] }
  let(:backoff) { described_class.new(clock: -> { now[0] }) }

  it "doubles the hold with each consecutive failure, to an hour at most", :aggregate_failures do
    holds = Array.new(5) { backoff.failed!(7) && (now[0] += 1) && (1..3600).find { |s| !held_after?(s) } }
    expect(holds.first).to be_between(598, 602)
    expect(holds.last).to be_between(3598, 3602)
  end

  def held_after?(seconds)
    saved = now[0]
    now[0] = saved + seconds
    backoff.held?(7)
  ensure
    now[0] = saved
  end
end
