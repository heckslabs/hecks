# frozen_string_literal: true

require "hecks/hecks/adapters/dispatching"

# The reopened probe of 2026-11-20 05:30: 9086 MB of headroom at the OS's normal level, a coder
# metered at 397 MB, floor 3072 and gap 2048, with the load the band was judged on.
module LoadBandReadings
  # @param band [String] the band the beat stood in
  # @param load [Integer] the 1-minute load in hundredths on six performance cores
  # @return [Hash] the beat as the door answered it
  def beat(band, load)
    { band: band, headroom: 9086, floor: 3072, gap: 2048, age: 0, stale_after: 120, draw: 397, metered_draw: 397,
      memory_pressure_level: 1, load: load, cores: 6, load_tight: 150, load_short: 300 }
  end

  # @param band [String] the band the beat stood in
  # @param load [Integer] the 1-minute load in hundredths
  # @return [Hecks::Adapters::Dispatching::Admitting] admission over a door that answers that beat
  def admitting(band, load)
    held = Hecks::Adapters::Dispatching::SignalboxDoor.new
    allow(held).to receive(:look).and_return(beat(band, load))
    Hecks::Adapters::Dispatching::Admitting.new(runs: {}, now: Time.now, door: held)
  end

  # @return [Hecks::Adapters::Dispatching::Plan::Item] a lower-tier coder's planned Work item
  def item = Hecks::Adapters::Dispatching::Plan::Item.new(key: "tiles", title: "tiles", priority: "next")
end
