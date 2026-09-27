require_relative "../../literal"
require_relative "../../vocabulary"

module Hecks
  # Adds `Common::COMPARATORS` and `.render_value`, the wire renderer shared by spec structs.
  module QuerySpecification
    # The clause structs, DSL mixin and comparison rules shared by every query-shaped construct.
    module Common
      # Includes `none_in_state`: `where ref: { none_in_state: "Claim:held" }` holds when no record
      # in the named aggregate, keyed by this field's value, is in that state (a keyed lookup).
      COMPARATORS = Hecks::Vocabulary.symbols("QueryComparator")
    end

    # Renders a query-clause literal as its wire spelling; delegates to `Hecks::Literal.render`.
    #
    # @param value [nil, Symbol, String, StateRef, Boolean, Integer, Float, Hash, Array] the
    #   literal as the bluebook author wrote it; Hash values and Array elements are
    #   rendered recursively
    # @return [String] the wire text: a Symbol keeps its colon, a String its double quotes,
    #   and a number, a boolean and `nil` are bare
    # @raise [ArgumentError] if `value`, or a value nested in it, is of any other class
    def self.render_value(value) = Literal.render(value)
  end
end
