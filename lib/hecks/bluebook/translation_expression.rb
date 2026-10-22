require_relative "translation_expression/parser"
require_relative "translation_expression/evaluator"

module Hecks
  module Bluebook
    # The expression a `derive` rule computes a new field from: text functions over the record's
    # stored text, with no storage engine in sight. It parses to a tree of plain arrays, which
    # is also its plan form:
    #
    #   ["ref", "name.value"]  ["lit", "text"]  ["null"]
    #   ["lower", x]  ["upper", x]  ["concat", x, y, ...]
    #   ["replace", x, ["lit", from], ["lit", to]]
    #   ["lookup", x, {"key" => "value"}, ["lit", default] | ["null"]]
    #
    # A reference that is missing or not text has no value, and a function with a valueless
    # argument has none either.
    module TranslationExpression
      # Raised when the text of an expression is not one the language accepts.
      class Refused < StandardError; end

      # The functions and how many expressions each takes; `nil` means "two or more".
      FUNCTIONS = { "lower" => 1, "upper" => 1, "concat" => nil, "replace" => 3, "lookup" => 3 }.freeze

      # Parses an expression's text into its tree.
      #
      # @param text [String] the expression, e.g. `lower(name.value)`
      # @return [Array] the expression tree
      # @raise [Refused] if the text is not a well-formed expression
      def self.parse(text) = Parser.new(text).call

      # Computes an expression's value for one record's state.
      #
      # @param tree [Array] a tree `parse` returned
      # @param state [Hash] the record's stored state
      # @return [String, nil] the text it computes; nil when it has no value
      def self.evaluate(tree, state) = Evaluator.call(tree, state)
    end
  end
end
