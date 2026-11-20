# frozen_string_literal: true

require "hecks/hecks/adapters/moving_cap"
require "hecks/signalbox/adapters/pressure_signal"
require_relative "in_force/switches"
require_relative "in_force/rules"
require_relative "in_force/sides"

module Hecks
  module Adapters
    module PipelineBoard
      # What governs a start at this moment, read from the switches the dispatch reads: the
      # Tickets world's `signalbox_pressure`, `admission`, `protection`, `reaping`, `work_cap` and
      # `main_verification` lines, and Signalbox's posted signal while it is current. Each setting
      # is said to be in force, standing by (and for what) or without effect (and why).
      module InForce
        module_function

        # @param registry [Runtime::Registry, nil] the booted registry holding the Tickets world
        # @param path [String] where Signalbox's pressure signal is posted
        # @param now [Time] the time the signal is read at
        # @return [Hash] `posted:` (the signal while current, whatever the switch says), `drives:`,
        #   `signal:` (the posted one while the switch has the readers read it), `moving:` (the
        #   moving cap, {MovingCap.standing}) and `row:` (a Tickets world line by verb)
        def reading(registry, path: PressureSignal.path, now: Time.now)
          tickets = registry&.world("Tickets")
          row = ->(verb) { (tickets&.for_verb(verb) || {}).transform_keys(&:to_sym) }
          posted = PressureSignal.current(path: path, now: now)
          drives = PressureSignal.drives?(row.call(PressureSignal::VERB))
          signal = posted if drives
          { posted: posted, drives: drives, signal: signal, row: row,
            moving: MovingCap.standing(registry, signal: signal) }
        end

        # @param dials [Array<Hash>] the settings rows
        # @param reading [Hash] {reading}
        # @return [Array<Hash>] each row with `force:` (`state` and `why`)
        def rows(dials, reading)
          dials.map { |dial| dial.merge(force: Rules.for(dial[:setting], reading)) }
        end

        # @param dials [Array<Hash>] the settings rows
        # @param reading [Hash] {reading}
        # @return [Hash{Symbol => Hash}] for load, admission, protection and reaping, the `side`
        #   that governs now and what it `says`
        def governs(dials, reading) = Sides.of(dials, reading)
      end
    end
  end
end
