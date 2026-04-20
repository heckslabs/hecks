# Hecks::DSL::FixtureBuilder
#
# Captures the body of a block-form `fixture` declaration:
#
#   fixture "ScienceExample" do
#     aggregate "TrainingExample"   # sets aggregate_name
#     input "A domain..."           # captured as :input attribute
#     category "science"            # captured as :category attribute
#   end
#
# The first positional arg to `fixture` becomes the fixture's `name`
# (a logical identifier for this instance). The `aggregate "X"` line
# inside the block sets the aggregate_name (the type). Every other
# `key "value"` line becomes an attribute. Multiple positional args
# (`key "a", "b"`) collapse into an array.
#
# Used by BluebookBuilder#fixture when a block is given.
#
module Hecks
  module DSL
    class FixtureBuilder
      attr_reader :aggregate_name, :attributes

      def initialize
        @aggregate_name = nil
        @attributes = {}
      end

      # `aggregate "TrainingExample"` — set this fixture's type.
      def aggregate(name)
        @aggregate_name = name.to_s
      end

      # Any other identifier becomes an attribute. `input "x"` →
      # @attributes[:input] = "x"; `tags "a", "b"` → @attributes[:tags] = ["a", "b"].
      def method_missing(name, *args, &_block)
        @attributes[name] = args.size == 1 ? args.first : args
      end

      def respond_to_missing?(_name, _include_private = false)
        true
      end
    end
  end
end
