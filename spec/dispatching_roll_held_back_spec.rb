require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A roll answers whether its filling left planned work waiting on the boot budget, the load or a
# pause, so the domain can start the idle chain from the answer alone.
RSpec.describe "a roll's held-back answer" do
  let(:pending) { Hecks::Adapters::Dispatching::Pending }
  let(:last_roll) { Hecks::Adapters::Dispatching::LastRoll }

  let(:roller) do
    Class.new do
      include Hecks::Adapters::Dispatching::Rolls

      def machine = Struct.new(:roll_forward?).new(true)

      def rolling_fill = "filled #{object_id}"
    end.new
  end

  before do
    pending.reset!
    allow(Hecks::Adapters::Dispatching::Filling).to receive(:running?).and_return(false)
    allow(last_roll).to receive(:repeat?).and_return(false)
  end

  it "answers zero when nothing was held back" do
    expect(roller.roll.dig(:held_back, :value)).to eq(0)
  end

  it "answers one when the boot budget stopped the filling" do
    pending.budget_stopped = true
    expect(roller.roll.dig(:held_back, :value)).to eq(1)
  end

  it "answers one when the machine held work back" do
    pending.load_stopped = true
    expect(roller.roll.dig(:held_back, :value)).to eq(1)
  end
end
