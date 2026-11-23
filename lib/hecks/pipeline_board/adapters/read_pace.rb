# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # How long the board rests after a read so that reading stays a small share of its time. A
      # read that cost more than the duty's share of the period is followed by a rest of
      # `cost / duty` seconds from the read's start; a cheaper read adds no rest, so a woken read
      # (a reply just made) still comes at once.
      class ReadPace
        # @param duty [Numeric] the share of time the board may spend reading; 0 for no bound
        # @param every [Numeric] the seconds between reads
        def initialize(duty:, every:)
          @duty = duty.to_f
          @every = every.to_f
        end

        # @param cost [Numeric] seconds the last read took
        # @return [Numeric] the seconds the next read waits at least, counted from the rest's
        #   start; 0 when the read was cheap or the duty is unbounded
        def rest_floor(cost)
          return 0 unless @duty.positive? && cost > @duty * @every

          cost / @duty
        end
      end
    end
  end
end
