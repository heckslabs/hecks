# frozen_string_literal: true

require "spec_helper"
require_relative "support/signalbox_door_wiring"
require_relative "support/os_level_readings"

# Admission reads memory the way the OS does: the beat looks at the meter the fill hands the door,
# which knows the live coders, so the kernel's memory pressure level and Roundhouse's metered draw
# reach `Admission.Admit` through a Signalbox booted standing alone.
RSpec.describe Hecks::Adapters::Dispatching::Admitting do
  include SignalboxDoorWiring
  include OsLevelReadings

  def admitting(level) = described_class.new(runs: {}, now: Time.now, door: door(metered: true), meter: -> { reading(level) })

  it "looks at the handed-in meter: the OS's level and the metered draw" do
    held = door(metered: true)
    expect(wired { held.look(meter: -> { reading(1) }) })
      .to include(band: "normal", headroom: 3072, memory_pressure_level: 1, metered_draw: 1100, draw: 1100)
  end

  it "admits a lower-tier coder at 3 GB of headroom while the OS reads its pressure normal" do
    expect(wired { admitting(1).reason(item) }).to be_nil
  end

  it "holds that coder by the gap at the same headroom while the OS's level is unread" do
    expect(wired { admitting(0).reason(item) }).to include("leaves the gap above the floor")
  end

  it "names the OS's level and the metered draw in the fill's clause" do
    expect(wired { admitting(1).clause }).to include("memory pressure level 1; draw 1100 metered")
  end
end
