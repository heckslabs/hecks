# frozen_string_literal: true

module Hecks
  module Adapters
    # Which load average the fill reads: the Tickets world's `load_average` dial names the minutes
    # (1, 5 or 15), 5 when the world names none or names a figure that is not an average. Every
    # reader of the machine's load takes its minutes from here, so the fill's limit, the expedite
    # bar, the Machine's marks and the board's guard compare one average.
    module LoadAverage
      # The world verb that carries the dial.
      VERB = "load_average"

      # The minutes read when the world names none.
      DEFAULT = 5

      # Each average's place among the three figures a system reports.
      PLACES = { 1 => 0, 5 => 1, 15 => 2 }.freeze

      module_function

      # @param registry [Runtime::Registry, nil] the booted registry whose Tickets world is read
      # @return [Integer] 1, 5 or 15: the world's `load_average` `minutes:`, else 5
      def minutes(registry)
        declared = registry&.world("Tickets")&.for_verb(VERB)
        named(declared.is_a?(Hash) ? declared.transform_keys(&:to_sym)[:minutes] : nil)
      end

      # @param value [Object] a figure from a world, a dial turn or a caller
      # @return [Integer] the value as minutes when it names an average, else 5
      def named(value)
        found = Integer(value.to_s, exception: false)
        PLACES.key?(found) ? found : DEFAULT
      end

      # @param figures [Array<Numeric>] the 1, 5 and 15-minute figures, in that order
      # @param minutes [Integer] the average wanted
      # @return [Float] that average, 0.0 when the figures lack it
      def pick(figures, minutes) = figures[PLACES.fetch(named(minutes))].to_f
    end
  end
end
