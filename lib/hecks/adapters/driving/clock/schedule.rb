require "time"
require_relative "cron"
require_relative "zone_time"

module Hecks
  module Adapters
    module Driving
      module Clock
        # The trigger of a declared clock as something that answers its next fire time.
        module Schedule
          # An interval, aligned to whole multiples of it since the Unix epoch, so a restart
          # keeps the same ticks.
          Every = Struct.new(:seconds) do
            # @param epoch [Integer] Unix seconds
            # @return [Integer] the first tick after `epoch`
            def next_after(epoch) = ((epoch / seconds) + 1) * seconds
          end

          # One instant; once it has passed there is no next fire.
          At = Struct.new(:epoch) do
            # @param after [Integer] Unix seconds
            # @return [Integer, nil] the instant, or nil once `after` has reached it
            def next_after(after) = epoch > after ? epoch : nil
          end

          # Seconds in each duration unit.
          UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

          # A duration literal: a whole number and one unit.
          DURATION = /\A(\d+)([smhd])\z/

          # An ISO-8601 instant that names its offset.
          INSTANT = /\A\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d)?(\.\d+)?(Z|[+-]\d\d:?\d\d)\z/

          module_function

          # @param clock [Bluebook::Clock] a declared clock
          # @return [Cron, Every, At] its trigger
          # @raise [ArgumentError] naming what is wrong with the trigger
          def for(clock)
            case clock.trigger.to_sym
            when :cron  then Cron.new(clock.expression, clock.zone)
            when :every then every(clock.expression)
            when :at    then at(clock.expression)
            end
          end

          # @param text [String] such as `"15m"`
          # @return [Every] the interval
          def every(text)
            match = DURATION.match(text.to_s)
            raise ArgumentError, "every #{text.inspect} is not a duration such as 30s, 15m, 1h or 1d" unless match

            seconds = Integer(match[1], 10) * UNITS.fetch(match[2])
            raise ArgumentError, "every #{text.inspect} is no time at all" unless seconds.positive?

            Every.new(seconds)
          end

          # @param text [String] such as `"2026-11-23T06:30:00-07:00"`
          # @return [At] the instant
          def at(text)
            unless INSTANT.match?(text.to_s)
              raise ArgumentError,
                    "at #{text.inspect} is not an ISO-8601 instant with an offset, such as 2026-11-23T06:30:00-07:00"
            end

            At.new(Time.iso8601(text.to_s).to_i)
          end
        end
      end
    end
  end
end
