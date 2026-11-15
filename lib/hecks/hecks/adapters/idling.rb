# frozen_string_literal: true

require_relative "ticking"

module Hecks
  module Adapters
    # The `Idling` port's adapter for `Idler`: starts the same detached chain {Ticking} starts, for
    # the one idle record of a store. Its ticks are `Idler.tick!`, they watch no pull request, and
    # its period is long and backs off, since each tick is a launcher boot. Whether the chain
    # goes on is the bluebook's, which refuses a tick when no chain stands or the beats pass the
    # limit.
    class Idling < Ticking
      # The Tickets world verb that carries the period in `seconds` and the allowance in `minutes`.
      VERB = "idles"

      # Seconds between the first ticks when the world names none.
      SECONDS = 300

      # Minutes a chain may tick when the world names none.
      MINUTES = 120

      # No quick period: the chain starts at the ladder's first step.
      QUICK_FOR = 0

      # Seconds between ticks, one step per tick, the last one repeating.
      STEPS = [300, 600, 1200].freeze

      AGGREGATE = "Idler"
      KEY = :idler

      private

      # The chain dispatches `Idler` and names its ticks by when it began, since one record keeps
      # every chain in turn; no branch is watched.
      def environment(_run)
        { "HECKS_CALLER" => "idler", "HECKS_TICK_BACKOFF" => backoff.to_s,
          "HECKS_TICK_AGGREGATE" => AGGREGATE, "HECKS_TICK_STAMP" => Time.now.to_i.to_s }
      end
    end
  end
end
