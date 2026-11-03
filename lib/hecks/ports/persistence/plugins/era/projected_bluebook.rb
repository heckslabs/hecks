require "digest"
require "json"

module Hecks
  module Runtime
    # A held era read from the storage shape its mint recorded, answering the bluebook questions an
    # era's diff, additive rule and coverage check ask of the side they translate from: each
    # aggregate's name, identity paths and attributes, and each value object's members.
    #
    # The shape is what an era is: its hash is the SHA-256 of the shape's canonical JSON, the same
    # one `StorageShape.mint_hash` takes of a declared bluebook. Nothing here parses held text.
    class ProjectedBluebook
      # One attribute or value-object member, by name and type name. The name is a Symbol and the
      # type name a String, as a declared bluebook answers them.
      Attribute = Data.define(:name, :type, :list) do
        # @return [Boolean] whether the attribute holds a list
        def list? = list
      end

      # A value object or entity an attribute's type names, with its members.
      Container = Data.define(:name, :attributes) do
        # @param name [String, Symbol] a member name
        # @return [Attribute, nil] the member of that name
        def attribute(name) = attributes.find { |member| member.name.to_s == name.to_s }
      end

      # One aggregate of the held shape.
      class Aggregate
        attr_reader :name, :identity_paths, :attributes

        # @param shape [Hash{String => Object}] one entry of the projection's `aggregates`
        def initialize(shape)
          @name = shape["name"]
          @identity_paths = Array(shape["identity"])
          @containers = {}
          @attributes = Array(shape["attributes"]).map { |attribute| read(attribute) }
        end

        # @param name [String, Symbol] an attribute name
        # @return [Attribute, nil] the attribute of that name
        def attribute(name) = attributes.find { |attribute| attribute.name.to_s == name.to_s }

        # @param type_name [String] a type name an attribute or member names
        # @return [Container, nil] the value object or entity of that name
        def value_object(type_name) = @containers[type_name]

        # @return [Array] none: entities are answered as containers by `value_object`
        def entities = []

        private

        # Reads one attribute or member, keeping the container its type expands to.
        def read(attribute)
          type = attribute["type"]
          type = contain(type) if type.is_a?(Hash)
          Attribute.new(name: attribute["name"].to_sym, type: type, list: attribute["list"] == true)
        end

        # Keeps the value object or entity a type expands to, and answers its name.
        def contain(type)
          name = type["type"]
          @containers[name] ||= Container.new(name: name, attributes: Array(type["members"]).map { |member| read(member) })
          name
        end
      end

      attr_reader :projection, :name, :aggregates

      # @param projection [Hash{String => Object}] a storage shape, as `StorageShape.project`
      #   answers it or as `hecks_eras.held_projection` stores it
      def initialize(projection)
        @projection = projection
        @name = projection["name"]
        @aggregates = Array(projection["aggregates"]).map { |shape| Aggregate.new(shape) }
      end

      # @param projection_or_bluebook [Hash, ProjectedBluebook, Object] a storage shape, a view, or
      #   a declared bluebook
      # @return [ProjectedBluebook, Object] a storage shape wrapped as a view; anything else as
      #   given
      def self.wrap(projection_or_bluebook)
        projection_or_bluebook.is_a?(Hash) ? new(projection_or_bluebook) : projection_or_bluebook
      end

      # @param name [String, Symbol] an aggregate name
      # @return [Aggregate, nil] the aggregate of that name
      def aggregate(name) = aggregates.find { |aggregate| aggregate.name == name.to_s }

      # @return [nil] a held shape carries no rename marker; the declared bluebook does
      def formerly_known_as = nil

      # @return [String] the era's hash: the SHA-256 of the shape's canonical JSON
      def mint_hash = Digest::SHA256.hexdigest(JSON.generate(Canonical.shape(projection)))

      # The storage shape with its keys in the order `StorageShape.project` builds them, so a shape
      # read back from `jsonb`, which reorders keys, hashes as it did when it was minted.
      module Canonical
        module_function

        # @param shape [Hash] a storage shape
        # @return [Hash] the shape with its keys in canonical order
        def shape(shape)
          { "name" => shape["name"], "aggregates" => Array(shape["aggregates"]).map { |aggregate| aggregate(aggregate) } }
        end

        # @return [Hash] one aggregate's shape in canonical key order
        def aggregate(aggregate)
          { "name" => aggregate["name"], "identity" => aggregate["identity"],
            "lifecycle_field" => aggregate["lifecycle_field"],
            "attributes" => Array(aggregate["attributes"]).map { |attribute| attribute(attribute) } }
        end

        # @return [Hash] one attribute's shape in canonical key order
        def attribute(attribute)
          { "name" => attribute["name"], "list" => attribute["list"], "type" => type(attribute["type"]) }
        end

        # @return [String, Hash] a scalar type as given, or a container in canonical key order
        def type(type)
          return type unless type.is_a?(Hash)

          { "type" => type["type"], "members" => Array(type["members"]).map { |member| attribute(member) } }
        end
      end
    end
  end
end
