# frozen_string_literal: true

require "hecks/catcher/adapters/spool_cursor"

module Hecks
  module Adapters
    # The `SpoolCursor` port's adapter for `Observation`: answers the `Acknowledge` ask by moving
    # the cursor beside the spool file past the lines a kept sitting holds.
    #
    # It never touches the spool. The cursor only moves forward.
    class SpoolCursorFile
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the spool file (default `SpoolCursor::DEFAULT_PATH`)
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @cursor = SpoolCursor.new(settings)
      end

      # Moves the cursor to `through`, never backward.
      #
      # @param held [Hash] `through:` the count to move to, plain or as `{ value: }`; the rest of
      #   the sitting is ignored
      # @return [Hash] empty
      # @raise [SystemCallError] when the cursor cannot be written
      def acknowledge(**held)
        through = held[:through]
        @cursor.advance((through.is_a?(Hash) ? through[:value] : through).to_i)
        {}
      end
    end
  end
end
