# frozen_string_literal: true

require "time"
require "hecks/signalbox/adapters/looking/marks"

module Hecks
  module Adapters
    class Dispatching
      # What {SignalboxDoor} answers when its own beat was not cleared (ADR 0222 law 2): the one
      # pressure signal a cleared beat posted, read through {PressureSignal}, which alone judges
      # whether it is still current. A beat from a linked worktree or the train copy is refused
      # clearance and posts nothing, yet it reads the machine the main checkout's beat reads, so
      # admission there reads the posted signal rather than calling the machine dark.
      #
      # The signal carries the band, the headroom and the load on its cores; the marks, the draw,
      # the OS's level and the metered draw come from the uncleared beat's own record, or, for a
      # beat that could not look at all, from the Signalbox world's marks with nothing read.
      #
      # It needs the including door's `runtime`, `beat_facts` and `@signal`.
      module PostedBeat
        # The band a look answers with no current reading at all.
        DARK = "dark"

        # The counts a look takes from the posted signal over the uncleared beat's own.
        SIGNALLED = %i[headroom load cores stale_after].freeze

        private

        # @param beat [Object, nil] the uncleared beat's record
        # @param now [Time] the time the signal is read at
        # @return [Hash] the posted band, headroom, load, cores and age over the marks, or the dark
        #   band
        def posted(beat, now: Time.now)
          marks = beat ? beat_facts(beat) : world_marks
          signal = @signal.call
          return { band: DARK, **marks } unless signal

          age = (now - Time.iso8601(signal[:posted_at].to_s)).to_i.clamp(0, nil)
          { **marks, band: signal[:band], **SIGNALLED.to_h { |fact| [fact, signal[fact].to_i] }, age: age }
        end

        # The marks a beat would have recorded, from the world the door's Signalbox reads, for a
        # beat that recorded no look: the OS's level is unread (0), no coder's draw is metered and
        # no load is read.
        def world_marks
          marks = Looking::Marks.new(runtime.registry).facts
          { headroom: 0, floor: marks[:floor], gap: marks[:gap], age: 0, stale_after: marks[:stale_after],
            draw: marks[:coder_draw], memory_pressure_level: 0, metered_draw: 0, load: 0, cores: 0,
            load_tight: marks[:load_tight], load_short: marks[:load_short] }
        end
      end
    end
  end
end
