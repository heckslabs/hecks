require "spec_helper"
require_relative "../support/simulated_delivery"

# A landing broken on purpose (`SimulatedDelivery::Lossy`) among a hundred agents: the simulation
# finds the landing it lost and shrinks the schedule to the fewest steps that still lose it.
RSpec.describe "A delivery simulation shrinking a lost landing", :aggregate_failures do
  include SimulatedDelivery

  before(:context) do
    @schedule = SimulatedDelivery::Generator.call(seed: 3)
    @shrunk = lossy.shrink(@schedule)
  end

  it "finds a landing that the broken landing lost" do
    found = lossy.run(@schedule)

    expect(found.agents.size).to eq(100)
    expect(fields(found)).to include("landed_is_on_main")
  end

  it "shrinks it to two agents and at most four steps, naming the landing main no longer holds" do
    expect([@shrunk.agents.size, @shrunk.schedule.size]).to eq([2, 4]).or eq([2, 3])
    expect(@shrunk.divergences.first[:detail]).to match(/the landing of \S+ is recorded at \S+, which main does not hold/)
    expect(fields(lossy.run(@shrunk.schedule))).to eq(["landed_is_on_main"])
  end

  it "holds every invariant on both schedules when the landing looks before it moves main" do
    expect([@schedule, @shrunk.schedule].flat_map { |schedule| simulation.run(schedule).divergences }).to eq([])
    expect { simulation.shrink(@shrunk.schedule) }.to raise_error(ArgumentError, /nothing to shrink/)
  end
end
