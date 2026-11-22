# frozen_string_literal: true

module Hecks
  module Adapters
    class Guarding
      module Loop
        # The numbers the loop compares against, as the bluebook's `Setting` rows declare them and
        # the roster file carries them. The loop holds none of its own.
        class Settings
          # @param rows [Hash{String => String}] key to value
          def initialize(rows)
            @rows = rows
          end

          # @param key [String] a setting's key
          # @return [Integer] its value as a number
          def number(key) = @rows.fetch(key).to_i

          # @return [Array<String>] the listed states that mean a session is gone
          def dead_states = @rows.fetch("dead_states").split(",").map(&:strip)
        end
      end
    end
  end
end
