require_relative "../clock"
require_relative "word_gate"

module Hecks
  module Bluebook
    module DSL
      # Parses one `clock "Name" do … end` block of a hecksagon into a `Bluebook::Clock`: exactly
      # one trigger (`cron`, `every` or `at`) and the command it dispatches.
      class ClockBuilder
        GRAMMAR_CONTEXT = "Clock".freeze

        include WordGate

        # @param name [String] the clock's name
        def initialize(name)
          @name     = name.to_s
          @triggers = []
        end

        # Fires on a five-field cron expression, in UTC unless `zone:` names a time zone.
        #
        # @param expression [String] minute, hour, day of month, month and day of week
        # @param zone [String, nil] a time zone name such as `"America/Phoenix"`
        # @return [void]
        def cron(expression, zone: nil) = @triggers << [:cron, expression.to_s, zone&.to_s]

        # Fires on an interval, aligned to whole multiples of it since the Unix epoch.
        #
        # @param duration [String] a whole number of `s`, `m`, `h` or `d`, such as `"15m"`
        # @return [void]
        def every(duration) = @triggers << [:every, duration.to_s, nil]

        # Fires once, at an ISO-8601 instant.
        #
        # @param instant [String] such as `"2026-11-23T06:30:00-07:00"`
        # @return [void]
        def at(instant) = @triggers << [:at, instant.to_s, nil]

        # Names the command each firing dispatches.
        #
        # @param command [String] `"Aggregate.Command"`
        # @param with [Hash{Symbol => Object}] the arguments, literal or a firing symbol
        # @param as [String, nil] the role the firing dispatches as
        # @return [void]
        def dispatch(command, with: {}, as: nil)
          @dispatch = { command: command.to_s, with: with.transform_keys(&:to_sym), role: as&.to_s }
        end

        # @return [Bluebook::Clock] the clock declared
        # @raise [Malformed] unless the block named exactly one trigger and a command
        def build
          refuse_malformed!
          trigger, expression, zone = @triggers.first
          Clock.new(name: @name, trigger: trigger, expression: expression, zone: zone, **@dispatch)
        end

        # Evaluates a clock block and answers the clock it declared.
        #
        # @param name [String] the clock's name
        # @return [Bluebook::Clock] the clock
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def refuse_malformed!
          unless @triggers.size == 1
            raise Malformed, "clock #{@name.inspect} names #{@triggers.size} triggers; it takes exactly one of cron, every or at"
          end
          raise Malformed, "clock #{@name.inspect} dispatches nothing; name a command with dispatch" unless @dispatch
        end
      end
    end
  end
end
