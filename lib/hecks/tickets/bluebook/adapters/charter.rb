# frozen_string_literal: true

module Hecks
  module Adapters
    # The `Charter` port's adapter for `Tickets::Epic`: the owner's charter as lines, first place
    # first, read from the `CharterLine` rows of the loaded Tickets bluebook. It reads and never
    # writes, so the rows stay the one place the charter is kept.
    class Charter
      # @param registry [Runtime::Registry, nil] the booted registry whose Tickets bluebook is read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
      end

      # @return [Hash{Symbol => String}] `text:` one line per charter line, ending in a newline
      def charter(**)
        { text: "#{rows.sort_by { |row| row[:place] }.map { |row| line(row) }.join("\n")}\n" }
      end

      private

      def line(row) = "#{row[:place]}. #{row[:theme]}: #{row[:covers]}"

      def rows = epic.value_objects.find { |object| object.hecks_name == "CharterLine" }.members

      def epic = @registry.bluebook("Tickets").aggregates.find { |aggregate| aggregate.hecks_name == "Epic" }
    end
  end
end
