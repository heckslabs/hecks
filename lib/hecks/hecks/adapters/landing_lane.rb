# frozen_string_literal: true

require_relative "../../vocabulary"

module Hecks
  module Adapters
    # The lane a work item's commits land on: the `Lane` row whose `lands_here` is "yes" in the
    # Vocabulary bluebook. The git adapters ask here, so no adapter holds a literal for it.
    module LandingLane
      module_function

      # @return [String] the name of the `Lane` row that lands here
      def name = Hecks::Vocabulary.rows("Lane").find { |row| row["lands_here"] == "yes" }.fetch("name")
    end
  end
end
