require "spec_helper"
require "hecks/hecks/adapters/rolling"

# The key a switch read hands its roll: the asking run and the time of the read, so two events
# about one work item each start a roll of their own.
RSpec.describe Hecks::Adapters::Rolling do
  subject(:rolling) { described_class.new(registry: nil, settings: { now: -> { Time.utc(2026, 11, 19, 1, 2, 3) } }) }

  before { allow(Hecks::Adapters::Dispatching::Settings).to receive(:new).and_return(double(roll_forward?: true)) }

  it "keys the roll by the asking run and the time of the read" do
    expect(rolling.read(run: { value: "alpha" }, paused: 0)[:roll]).to eq(value: "alpha@2026-11-19T01:02:03.000000000Z")
  end
end
