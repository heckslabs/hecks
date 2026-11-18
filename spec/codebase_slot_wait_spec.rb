# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/codebase/heavy_slots"

# A wait ends only when the line has stopped moving.
RSpec.describe Hecks::Adapters::Codebase::SlotWait do
  let(:times) { [0, 10, 20, 30, 40].each }
  let(:wait) { described_class.new({}, -> { times.next }, 0, 25) }

  it "does not end a wait while the tickets ahead keep falling" do
    queue = instance_double(Hecks::Adapters::Codebase::SlotQueue)
    allow(queue).to receive(:ahead).and_return(5, 4, 3, 2)
    expect(Array.new(4) { wait.stalled?(queue) }).to eq([false] * 4)
  end

  it "ends a wait once the number ahead has not fallen for the bound" do
    queue = instance_double(Hecks::Adapters::Codebase::SlotQueue, ahead: 3)
    expect(Array.new(4) { wait.stalled?(queue) }).to eq([false, false, false, true])
  end
end
