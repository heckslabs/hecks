# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_github"

# The hold a failed failed-job log read earns: 10 minutes, doubling per consecutive failure to an hour.
RSpec.describe Hecks::Adapters::PipelineBoard::LogBackoff do
  let(:now) { [0] }
  let(:backoff) { described_class.new(clock: -> { now[0] }) }

  it "holds nothing that never failed" do
    expect(backoff.held?(7)).to be(false)
  end

  it "holds a failed job for 10 minutes", :aggregate_failures do
    backoff.failed!(7)
    now[0] = 599
    expect(backoff.held?(7)).to be(true)
    now[0] = 600
    expect(backoff.held?(7)).to be(false)
  end

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

  it "forgets a job whose read succeeded" do
    backoff.failed!(7)
    backoff.clear!(7)
    expect(backoff.held?(7)).to be(false)
  end

  it "lets go of a failure long past its hold" do
    backoff.failed!(7)
    now[0] = 10_000
    backoff.held?(8)
    expect(backoff.size).to eq(0)
  end
end
