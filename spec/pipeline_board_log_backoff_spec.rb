# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_github/log_backoff"

# The hold a failed failed-job log read earns: 10 minutes, doubling per failure up to an hour.
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
