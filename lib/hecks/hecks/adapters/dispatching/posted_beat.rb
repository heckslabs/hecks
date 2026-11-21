# frozen_string_literal: true

require "time"
require "hecks/signalbox/adapters/looking/marks"

module Hecks
  module Adapters
    class Dispatching
      # What {SignalboxDoor} answers when its own beat was not cleared (ADR 0222 law 2): a beat from
      # a worktree or the train copy opens no Pressure and posts nothing. In order, admission reads
      # the signal a cleared beat posted ({PressureSignal} judges it current; it wins, as the
      # shared signal), else the beat's own current look judged by Signalbox's band policies with
      # `posts` no (an uncleared view may judge, never post; a look past `stale_after` is refused
      # and is no reading), else the dark band.
      #
      # It needs the including door's `runtime`, `beat_facts`, `record` and `@signal`.
      module PostedBeat
        # The band a look answers with no current reading at all.
        DARK = "dark"

        # The counts a look takes from the posted signal over the uncleared beat's own.
        SIGNALLED = %i[headroom load cores stale_after].freeze

        # The `Beat` fields a judged look hands `Pressure.Read`.
        JUDGED = %i[headroom target floor gap load cores load_tight load_short load_gap
                    memory_pressure_level coders_fit gates_fit age stale_after].freeze

        private

        # @param beat [Object, nil] the uncleared beat's record
        # @param now [Time] the time the signal is read at
        # @return [Hash] the posted band, headroom, load, cores and age over the marks; else the
        #   band the beat's own current look judges; else the dark band
        def posted(beat, now: Time.now)
          marks = beat ? beat_facts(beat) : world_marks
          signal = @signal.call
          return { **marks, **signalled(signal, now) } if signal

          { **marks, band: judged_band(beat) || DARK }
        end

        def signalled(signal, now)
          age = (now - Time.iso8601(signal[:posted_at].to_s)).to_i.clamp(0, nil)
          { band: signal[:band], **SIGNALLED.to_h { |fact| [fact, signal[fact].to_i] }, age: age }
        end

        # The band Signalbox's policies settle on the beat's own look, kept in this door's own
        # Memory runtime and never posted.
        #
        # @param beat [Object, nil] the uncleared beat's record
        # @return [String, nil] the band; nil when the beat recorded no look or its look is stale
        def judged_band(beat)
          return unless beat && value(beat, :capacity).to_i.positive?

          key = value(beat, :beat)
          open = { pressure: { value: key }, capacity: { value: value(beat, :capacity) } }
          runtime.dispatch("Signalbox::Pressure.Open", with: open)
          runtime.dispatch("Signalbox::Pressure.Read", to: key, with: judged_read(beat))
          value(record("Pressure", key), :band)
        rescue Hecks::Refused
          nil
        end

        def judged_read(beat)
          { posts: { value: "no" }, **JUDGED.to_h { |field| [field, { value: value(beat, field) }] } }
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
