# frozen_string_literal: true

require "hecks/signalbox/adapters/pressure_signal"

module Hecks
  module Adapters
    class Dispatching
      # The limits of a filling that Signalbox's pressure signal replaces while the owner has
      # `signalbox_pressure` drive them (ADR 0222, phase 3b): the pause is the short band, the room
      # is the coders the headroom fits, and the load average is not a limit of its own (the band
      # already holds the load). None while the switch is off or the signal is dark, so the
      # fill keeps its own load guard then.
      module PressureLimits
        # How a pause by the short band begins; an expedited item passes it, as an urgent coder is
        # admitted in every band.
        PAUSE = "skipped: pressure short"

        module_function

        # @param registry [Runtime::Registry, nil] whose Tickets world carries the switch
        # @param signal [Hash, nil] a stand-in for the current signal; the posted one when absent
        # @return [Hash] `paused:`, `max_load:`, `headroom:` and `per_session:`, or none
        def of(registry, signal: nil)
          signal ||= PressureSignal.standing(registry)
          signal ? limits(signal) : {}
        end

        # @param signal [Hash] a current signal
        # @return [Hash] the limits it sets
        def limits(signal)
          { paused: PressureSignal.short?(signal) ? "#{PAUSE}: #{PressureSignal.said(signal)}" : nil,
            max_load: Float::INFINITY, headroom: PressureSignal.coders(signal), per_session: nil }
        end

        # @param pause [String, nil] a filling's pause
        # @return [Boolean] whether the short band set it
        def pause?(pause) = pause.to_s.start_with?(PAUSE)
      end
    end
  end
end
