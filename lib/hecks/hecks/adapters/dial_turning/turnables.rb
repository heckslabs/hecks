# frozen_string_literal: true

module Hecks
  module Adapters
    class DialTurning
      # The `Turnable` rows of the Hecks bluebook's `Dial` aggregate: the settings a turn may set,
      # each with its world, its kind and its bounds. They are read from the booted IR, so the
      # command that turns a setting and the board that shows it answer from one declaration.
      module Turnables
        # The aggregate that holds the rows, and the value object they are members of.
        OWNER = "Dial"
        SHAPE = "Turnable"
        # What a switch may be turned to, each with the value it writes.
        SWITCH = { "on" => true, "true" => true, "off" => false, "false" => false }.freeze

        module_function

        # @param aggregate [Bluebook::Aggregate, nil] the `Dial` aggregate's IR
        # @return [Array<Hash{Symbol => String}>] each row's `world`, `setting`, `kind`, `least`,
        #   `most`, `context` and `says`; none when the aggregate is absent
        def of(aggregate)
          shape = aggregate&.value_objects&.find { |object| object.hecks_name == SHAPE }
          Array(shape&.members).map { |row| row.to_h.transform_keys(&:to_sym) }
        end

        # @param registry [Runtime::Registry, nil] a booted registry holding the Hecks bluebook
        # @return [Array<Hash{Symbol => String}>] the rows; none when the registry is absent
        def from_registry(registry)
          bluebook = registry&.bluebooks.to_h["Hecks"]
          of(bluebook&.aggregates&.find { |candidate| candidate.hecks_name == OWNER })
        end

        # @param row [Hash] a row
        # @param text [String] what the setting is turned to, as it was typed
        # @return [Integer, Float, Boolean] the value the world file holds
        # @raise [ArgumentError] when the text is not of the row's kind, or is outside its bounds
        def value(row, text)
          return switch(row, text) if row[:kind] == "switch"

          number = number_of(row, text)
          return number if number.between?(Float(row[:least]), Float(row[:most]))

          raise ArgumentError, "#{row[:setting]} is turned between #{row[:least]} and #{row[:most]}, not to #{text}"
        end

        def number_of(row, text)
          row[:kind] == "integer" ? Integer(text.to_s, 10) : Float(text.to_s)
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{row[:setting]} takes a #{row[:kind]}, not #{text.inspect}"
        end

        def switch(row, text)
          SWITCH.fetch(text.to_s.downcase) { raise ArgumentError, "#{row[:setting]} is turned on or off, not #{text.inspect}" }
        end
      end
    end
  end
end
