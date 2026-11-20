require "spec_helper"
require_relative "support/machine_beats"

# Each recorded reading of the machine carries when it was taken, stamped behind the Sampling
# port, so the next reading stands on the one taken latest.
RSpec.describe "the stamp on a recorded machine reading" do
  include MachineBeats

  def stamps_of(registry)
    machine = registry.bluebook("Hecks").aggregates.find { |each| each.hecks_name == "Machine" }
    registry.repository("Hecks", machine).all.map { |held| Hecks::Adapters::StartedWork.value(held, :taken_at) }
  end

  it "records when each reading was taken, in ISO-8601 UTC" do
    stamps = stamps_of(beat_through([gauge(60.0).merge(load: 11.0)])[:registry])

    expect(stamps).to all(match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/))
  end

  it "hears the load fall after a rise, standing on the stamped reading before" do
    names = beat_through([11.0, 8.0].map { |load| gauge(60.0).merge(load: load) })[:names]

    expect(names.grep(/\ALoad(Rose|Fell)/)).to eq(%w[LoadRoseAbove LoadFellBelow])
  end
end
