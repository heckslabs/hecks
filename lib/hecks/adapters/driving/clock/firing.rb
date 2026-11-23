require_relative "zone_time"

module Hecks
  module Adapters
    module Driving
      module Clock
        # One firing of a clock: the instant it was due, and the arguments the clock's `with`
        # resolves to then. A symbol names what the firing knows; anything else is a literal.
        class Firing
          # What a `with` symbol may name, each read off the due instant in the clock's zone.
          KNOWN = {
            fire_date: ->(local, _clock) { local.strftime("%Y-%m-%d") },
            fire_time: ->(local, _clock) { local.iso8601 },
            firing_id: ->(local, clock) { "#{clock.name}-#{local.strftime("%Y-%m-%dT%H:%M:%S")}" }
          }.freeze

          attr_reader :clock, :due

          # @param clock [Bluebook::Clock] the clock that fired
          # @param due [Integer] the Unix seconds the firing was due
          def initialize(clock, due)
            @clock = clock
            @due = due
          end

          # @return [Hash{Symbol => Object}] the command's arguments for this firing
          def arguments
            clock.arguments.transform_values { |value| value.is_a?(Symbol) ? KNOWN.fetch(value).call(local, clock) : value }
          end

          # @return [Time] the due instant as the clock's zone reads it
          def local = ZoneTime.local(due, clock.zone)

          # @return [String] the due instant in ISO-8601, in the clock's zone
          def to_s = local.iso8601
        end
      end
    end
  end
end
