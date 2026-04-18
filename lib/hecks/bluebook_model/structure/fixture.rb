# Hecks::BluebookModel::Structure::Fixture
#
# An instance of an aggregate that ships with the domain definition.
# Fixtures are the domain's own data — declared inline in the Bluebook,
# loaded when the domain boots. Both Ruby and Rust read them as initial state.
#
# Two source forms produce a Fixture:
#
#   # inline: first positional arg is the aggregate name, kwargs are attributes
#   fixture "NonVerbSuffix", suffix: "ment", part_of_speech: "noun"
#
#   # block: first positional arg is the fixture's `name` (identifier),
#   # `aggregate "X"` inside the block sets aggregate_name, every other
#   # `key "value"` line becomes an attribute.
#   fixture "ScienceExample" do
#     aggregate "TrainingExample"
#     input "A domain..."
#     category "science"
#   end
#
module Hecks
  module BluebookModel
    module Structure
      class Fixture
        # @return [String, nil] identifier for this fixture instance (block form only)
        attr_reader :name

        # @return [String] the aggregate this fixture instantiates
        attr_reader :aggregate_name

        # @return [Hash] the attribute values for this instance
        attr_reader :attributes

        # @param aggregate_name [String] which aggregate this is an instance of
        # @param attributes [Hash] attribute key-value pairs
        # @param name [String, nil] optional identifier (block form)
        def initialize(aggregate_name:, attributes: {}, name: nil)
          @aggregate_name = aggregate_name.to_s
          @attributes = attributes
          @name = name
        end

        def ==(other)
          other.is_a?(Fixture) &&
            aggregate_name == other.aggregate_name &&
            attributes == other.attributes &&
            name == other.name
        end
        alias eql? ==

        def hash
          [name, aggregate_name, attributes].hash
        end
      end
    end
  end
end
