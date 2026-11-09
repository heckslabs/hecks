require "spec_helper"
require "hecks/adapters/driving/resident/wire"

# The one allowance of time for a caller's whole exchange with a resident (ADR 0201).
RSpec.describe Hecks::Adapters::Driving::Resident::Wire::Deadline do
  let(:time) { [0.0] }
  let(:deadline) { described_class.new(5, clock: -> { time.first }) }

  it "counts down from when it is made, and is zero once it has passed", :aggregate_failures do
    deadline
    time[0] = 3.0
    expect(deadline.left).to eq(2.0)
    time[0] = 9.0
    expect(deadline.left).to eq(0.0)
  end

  it "starts with all of its seconds" do
    expect(deadline.left).to eq(5.0)
  end
end
