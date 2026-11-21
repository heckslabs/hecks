# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class Guarding
      module Loop
        # What the loop remembers between passes: which sessions it saw gone and when, and which it
        # resumed and when. Kept as one JSON file, so a loop that is restarted carries on.
        class State
          EMPTY = { "vanished" => {}, "resumed" => {}, "noted" => 0 }.freeze

          # @param home [String] the loop's directory
          def initialize(home)
            @path = File.join(home, "state.json")
            @data = read
          end

          # @return [Hash{String => Integer}] session name to the moment it was seen gone
          def vanished = @data["vanished"]

          # @return [Hash{String => Integer}] session name to the moment it was resumed
          def resumed = @data["resumed"]

          # @return [Integer] the moment of the last mass vanishing recorded
          def noted = @data["noted"]

          # @param moment [Integer] the moment of the mass vanishing just recorded
          def noted=(moment)
            @data["noted"] = moment
          end

          # @return [void]
          def save = File.write(@path, JSON.generate(@data))

          private

          def read
            JSON.parse(File.read(@path))
          rescue SystemCallError, JSON::ParserError
            JSON.parse(JSON.generate(EMPTY))
          end
        end
      end
    end
  end
end
