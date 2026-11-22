# frozen_string_literal: true

module Hecks
  module Adapters
    class PaceReading
      # The rows `Pace` declares: its windows, the noise events and the finished events.
      class Rows
        # @param aggregate [Bluebook::Aggregate, nil] `Pace`
        def initialize(aggregate)
          @aggregate = aggregate
        end

        # @param label [String, nil] a window's label
        # @return [Hash] the `Window` row with that label, the first row when none matches
        def window(label)
          all = members("Window")
          all.find { |row| row[:label] == label.to_s } || all.first || { label: "1h", seconds: 3_600 }
        end

        # @return [Array<String>] the events that are noise
        def noise = members("Noise").map { |row| row[:event] }

        # @return [Array<String>] the events that say an item finished
        def finished = members("Finished").map { |row| row[:event] }

        private

        def members(name)
          rows = @aggregate&.value_objects&.find { |object| object.hecks_name == name }
          Array(rows&.members).map { |row| row.to_h.transform_keys(&:to_sym) }
        end
      end
    end
  end
end
