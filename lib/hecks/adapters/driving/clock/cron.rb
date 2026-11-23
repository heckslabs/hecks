require "date"
require_relative "zone_time"

module Hecks
  module Adapters
    module Driving
      module Clock
        # A five-field cron expression (minute, hour, day of month, month, day of week) read in
        # one zone, and the next minute it names after a given instant.
        #
        # Each field takes `*`, a number, a range `a-b`, a step `*/n` or `a-b/n`, and lists of
        # these. When both day fields are restricted a day matching either fires, as cron does.
        class Cron
          # The fields in order, each with its lowest and highest value.
          FIELDS = { minute: 0..59, hour: 0..23, day: 1..31, month: 1..12, weekday: 0..7 }.freeze

          # How many days ahead a search looks before it says the expression never fires.
          HORIZON_DAYS = 366 * 5

          attr_reader :expression, :zone

          # @param expression [String] the five fields
          # @param zone [String, nil] a time zone name; nil is UTC
          # @raise [ArgumentError] naming what is wrong with the expression or the zone
          def initialize(expression, zone = nil)
            @expression = expression.to_s
            @zone = zone
            raise ArgumentError, "zone #{zone.inspect} is not a time zone name this machine knows" unless ZoneTime.known?(zone)

            @sets = parse_fields
          end

          # @param epoch [Integer] Unix seconds
          # @return [Integer, nil] the first minute the expression names after `epoch`
          def next_after(epoch)
            start = ZoneTime.local(epoch, zone).to_date
            (0..HORIZON_DAYS).each do |offset|
              found = first_on(start + offset, epoch)
              return found if found
            end
            nil
          end

          private

          def first_on(date, epoch)
            return unless day?(date)

            @sets[:hour].each do |hour|
              @sets[:minute].each do |minute|
                found = ZoneTime.epoch(zone, date.year, date.month, date.day, hour, minute)
                return found if found > epoch
              end
            end
            nil
          end

          def day?(date)
            return false unless @sets[:month].include?(date.month)

            on_day = @sets[:day].include?(date.day)
            on_weekday = @sets[:weekday].include?(date.wday)
            return on_day || on_weekday if restricted?(:day) && restricted?(:weekday)

            on_day && on_weekday
          end

          def restricted?(field) = @fields[field] != "*"

          def parse_fields
            parts = expression.split
            raise ArgumentError, "cron #{expression.inspect} needs five fields, has #{parts.size}" unless parts.size == 5

            @fields = FIELDS.keys.zip(parts).to_h
            sets = @fields.to_h { |field, text| [field, values(field, text)] }
            sets.merge(weekday: sunday_once(sets[:weekday]))
          end

          # Day 7 is Sunday as well as day 0.
          def sunday_once(days) = days.map { |day| day % 7 }.uniq.sort

          def values(field, text)
            listed = text.split(",").flat_map { |part| part_values(field, part) }
            listed.uniq.sort
          end

          def part_values(field, part)
            range, step = part.split("/", 2)
            bounds = range == "*" ? FIELDS[field] : bounded(field, range)
            step_by = step ? number(field, step) : 1
            raise ArgumentError, "cron #{field} step must be positive in #{expression.inspect}" unless step_by.positive?

            bounds.step(step_by).to_a
          end

          def bounded(field, range)
            low, high = range.split("-", 2).map { |end_point| number(field, end_point) }
            high ||= low
            unless FIELDS[field].cover?(low) && FIELDS[field].cover?(high) && low <= high
              raise ArgumentError, "cron #{field} #{range.inspect} is outside #{FIELDS[field]} in #{expression.inspect}"
            end

            low..high
          end

          def number(field, text)
            Integer(text, 10)
          rescue ArgumentError
            raise ArgumentError, "cron #{field} #{text.inspect} is not a number in #{expression.inspect}"
          end
        end
      end
    end
  end
end
