# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# How long the board rests after reading its state: a read that costs more than its share of the
# period is followed by a rest that brings the board's busy share down to the duty, and a cheap
# read is followed by no extra rest, so a reply still shows at once.
RSpec.describe Hecks::Adapters::PipelineBoard::ReadPace do
  let(:pace) { described_class.new(duty: 0.1, every: 30) }

  it "rests ten times a read's cost after a read that cost 25 seconds at a duty of a tenth" do
    expect(pace.rest_floor(25)).to eq(250)
  end

  it "adds no rest after a read that cost no more than the duty's share of the period" do
    expect(pace.rest_floor(3)).to eq(0)
  end

  it "adds no rest when the duty is zero" do
    expect(described_class.new(duty: 0, every: 30).rest_floor(500)).to eq(0)
  end

  it "takes the duty from the board_restart limits" do
    expect(Hecks::Adapters::PipelineBoard::BoardRestart.limits(nil)[:read_duty]).to eq(0.1)
  end
end
