# Hecks::BluebookModel::Structure::Fixture
#
# An instance of an aggregate that ships with the domain definition.
# Fixtures are the domain's own data — declared inline in the Bluebook,
# loaded when the domain boots. Both Ruby and Rust read them as initial state.
#
#   fixture = Fixture.new(aggregate_name: "NonVerbSuffix", attributes: { suffix: "ment", part_of_speech: "noun" })
#   fixture.aggregate_name  # => "NonVerbSuffix"
#   fixture.attributes      # => { suffix: "ment", part_of_speech: "noun" }
#
module Hecks
  module BluebookModel
    module Structure
      class Fixture
        # @return [String] the aggregate this fixture instantiates
        attr_reader :aggregate_name

        # @return [Hash] the attribute values for this instance
        attr_reader :attributes

        # @param aggregate_name [String] which aggregate this is an instance of
        # @param attributes [Hash] attribute key-value pairs
        def initialize(aggregate_name:, attributes: {})
          @aggregate_name = aggregate_name.to_s
          @attributes = attributes
        end

        def ==(other)
          other.is_a?(Fixture) && aggregate_name == other.aggregate_name && attributes == other.attributes
        end
        alias eql? ==

        def hash
          [aggregate_name, attributes].hash
        end
      end
    end
  end
end
