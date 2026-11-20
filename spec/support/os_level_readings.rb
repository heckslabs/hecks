# frozen_string_literal: true

require "hecks/hecks/adapters/dispatching"

# The readings of the probe of 2026-11-20: 3072 to 4800 MB of headroom while the OS read its memory
# pressure normal (level 1), for the admission specs that read memory the way the OS does.
module OsLevelReadings
  # The machine with 3072 MB of headroom past the 8192 MB reserve, its coders metered at 1100 MB.
  #
  # @param level [Integer] the kernel's memory pressure level
  # @return [Hash] the machine facts a meter answers
  def reading(level)
    { capacity_mb: 36_864, used_mb: 25_600, load: 700, cores: 6, coder_draw_mb: 1_100, memory_pressure_level: level }
  end

  # The beat as the door answered it at 00:56: 4800 MB of headroom, the world's draw.
  #
  # @param level [Integer] the kernel's memory pressure level the beat read
  # @return [Hecks::Adapters::Dispatching::SignalboxDoor] a door whose look answers that beat
  def door_at(level)
    beat = { band: "normal", headroom: 4800, floor: 3072, gap: 2048, age: 0, stale_after: 120, draw: 1536,
             memory_pressure_level: level, metered_draw: 0 }
    Hecks::Adapters::Dispatching::SignalboxDoor.new.tap { |held| allow(held).to receive(:look).and_return(beat) }
  end

  # @return [Hecks::Adapters::Dispatching::Plan::Item] a lower-tier coder's planned Work item
  def item = Hecks::Adapters::Dispatching::Plan::Item.new(key: "tiles", title: "tiles", priority: "next")
end
