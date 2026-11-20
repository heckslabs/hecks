# frozen_string_literal: true

require_relative "../console_capture"
require_relative "fill_stall"

module Hecks
  module Adapters
    class Dispatching
      # The question the fill's watch puts to the queue: has it gone quiet. It reads the same
      # plan, machine and started items as the preview and writes nothing.
      module FillLooks
        # @param _held [Hash] the `FillWatch` record
        # @return [Hash{Symbol => Hash}] `reason:`, `reading:`, `held_minutes:` and `governed_by:`
        # @raise [ConsoleCapture::Failure] when a start is recent, nothing waits, or no room is left
        def look_at_fill(**_held)
          started = work_items.started
          quiet = FillStall.minutes_quiet(started.map(&:key), clock)
          plan = plan_for
          raise ConsoleCapture::Failure, flowing_note(plan, started, quiet) if flowing?(plan, started, quiet)

          stalled_answer(plan, started, quiet)
        end

        private

        def flowing?(plan, started, quiet)
          quiet < FillStall::WINDOW_MINUTES || plan.skipped.empty? || started.size >= machine.cap
        end

        def flowing_note(plan, started, quiet)
          "flowing: #{started.size} started, #{plan.skipped.size} waiting, #{quiet.floor} minutes since a start"
        end

        def stalled_answer(plan, started, quiet)
          facts = { reason: "held by #{FillStall.dominant(plan.skipped)}", reading: fill_reading(started),
                    governed_by: FillStall.governor(plan.skipped), minutes: quiet.floor }
          { reason: { value: facts[:reason] }, reading: { value: facts[:reading] },
            held_minutes: { value: facts[:minutes] }, governed_by: { value: facts[:governed_by] },
            since: { value: (clock - (quiet * 60)).utc.strftime("%Y-%m-%dT%H:%M:%SZ") },
            detail: { value: FillStall.detail(facts) } }
        end

        def fill_reading(started)
          gauge = machine
          "load #{gauge.load.round(1)} from #{gauge.load_source} against load_high #{gauge.max_load.round(1)}; " \
            "#{started.size} started of cap #{gauge.cap}"
        end
      end
    end
  end
end
