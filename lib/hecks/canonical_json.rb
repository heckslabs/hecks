# frozen_string_literal: true

require "json"

module Hecks
  # A JSON document with every object's keys sorted. Key order is not semantics, so a diff a person
  # reads should not have to notice it moved.
  module CanonicalJson
    module_function

    # Sorts every Hash's keys within a parsed JSON document, recursively.
    #
    # @param node [Object] a value from `JSON.parse`: a `Hash`, an `Array`, or a JSON scalar
    # @return [Object] the same shape with every nested `Hash`'s keys sorted by their string form
    def sort_deep(node)
      case node
      when Hash then node.sort_by { |key, _| key.to_s }.to_h { |key, value| [key, sort_deep(value)] }
      when Array then node.map { |item| sort_deep(item) }
      else node
      end
    end

    # @param text [String] a JSON document
    # @return [String] the document pretty-printed with its keys in order
    # @raise [JSON::ParserError] if the text is not JSON
    def pretty(text)
      JSON.pretty_generate(sort_deep(JSON.parse(text)))
    end
  end
end
