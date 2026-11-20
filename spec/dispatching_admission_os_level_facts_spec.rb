# frozen_string_literal: true

require "spec_helper"
require_relative "support/os_level_readings"

# The facts a fill puts to `Admission.Admit` carry the OS's memory pressure level the door
# answered, so the probe's beat of 2026-11-20 00:56 admits a coder at level 1.
RSpec.describe Hecks::Adapters::Dispatching::Admitting do
  include OsLevelReadings

  def admitting(level) = described_class.new(runs: {}, now: Time.now, door: door_at(level))

  it "admits a lower-tier coder while the OS reads its pressure normal" do
    expect(admitting(1).reason(item)).to be_nil
  end

  it "holds that coder by the gap while the OS's level is unread" do
    expect(admitting(0).reason(item)).to include("leaves the gap above the floor")
  end

  it "hands the door the meter it is given" do
    meter = -> { {} }
    held = door_at(1)
    described_class.new(runs: {}, now: Time.now, door: held, meter: meter)
    expect(held).to have_received(:look).with(meter: meter)
  end

  it "names the world's draw in its clause while no coder is metered" do
    expect(admitting(0).clause).to include("memory pressure level 0; draw 1536 the world's")
  end
end
