# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What a confirmed filling did with the work items it chose: one outcome for each, counted by
      # kind and never by reading a line's text.
      class FillReport
        # One chosen work item's result.
        # kind is `:started`, `:yielded` (back to the plan, with the reason on the line) or `:stuck`
        # (neither started nor yielded).
        Outcome = Struct.new(:kind, :line)

        # @param outcomes [Array<Outcome>] one for each chosen work item, in plan order
        def initialize(outcomes)
          @outcomes = outcomes
        end

        # @return [Array<String>] one line for each chosen work item
        def lines = @outcomes.map(&:line)

        # @param chosen [Integer] how many work items the plan chose
        # @return [String] the header's clause, such as `this fill: 4 started, 4 yielded of 8`
        def tally(chosen)
          "this fill: #{count(:started)} started, #{count(:yielded)} yielded#{stuck_clause} of #{chosen}"
        end

        private

        def count(kind) = @outcomes.count { |outcome| outcome.kind == kind }

        def stuck_clause = count(:stuck).zero? ? "" : ", #{count(:stuck)} stuck"
      end
    end
  end
end
