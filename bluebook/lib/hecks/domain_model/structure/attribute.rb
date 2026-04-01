module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::Attribute
    #
    # Represents a typed attribute on an aggregate, value object, command, or event.
    # Supports scalar types (String, Integer) and list types.
    #
    # The most granular building block in the DomainModel IR. Used by every builder
    # and every generator.
    #
    #   attr = Attribute.new(name: :name, type: String)
    #   json_attr = Attribute.new(name: :points, type: JSON)
    #   json_attr.json?  # => true
    #
    class Attribute
      # @return [Symbol] the attribute name as a symbol (e.g., :name, :status, :email)
      attr_reader :name

      # @return [Class, String] the type of this attribute. Can be a Ruby class (String, Integer,
      #   Float, Date, DateTime, JSON) or a string referencing another aggregate/value object name.
      attr_reader :type

      # @return [Object, nil] the default value for this attribute, or nil if no default is set.
      #   Used by generators to set initial values in constructors.
      attr_reader :default

      # @return [Array<String>, nil] the allowed enum values for this attribute, or nil if not
      #   an enum. When set, generated code validates that values are within this list.
      attr_reader :enum

      # Creates a new Attribute.
      #
      # @param name [Symbol, String] the attribute name. Will be converted to a Symbol via +to_sym+.
      # @param type [Class, String] the attribute's type. Use Ruby classes for primitives
      #   (String, Integer, Float, Date, DateTime, JSON) or a string name for references
      #   to other aggregates or value objects.
      # @param default [Object, nil] optional default value for code generation.
      # @param list [Boolean] if true, this attribute holds a collection (Array) of the given type.
      # @param pii [Boolean] if true, this attribute contains personally identifiable information
      #   and should be handled according to PII policies (encryption, masking, etc.).
      # @param enum [Array<String>, nil] optional list of allowed string values. When present,
      #   generated code will validate that the attribute value is one of these.
      # @param visible [Boolean] if false, this attribute is hidden from the web explorer
      #   and generated UI (index tables, show pages, home cards). Useful for internal fields
      #   like passwords, tokens, or raw foreign keys that should not be displayed to users.
      #
      # @return [Attribute] a new Attribute instance
      def initialize(name:, type:, default: nil, list: false, pii: false, enum: nil, visible: true)
        @name = name.to_sym
        @type = type
        @default = default
        @list = list
        @pii = pii
        @enum = enum
        @visible = visible
      end

      # Returns true if this attribute holds a collection of values.
      # List attributes are generated as Array types and support
      # add/remove operations in commands.
      #
      # @return [Boolean] true if this is a list/collection attribute
      def list?
        @list
      end

      # Returns true if this attribute contains personally identifiable information.
      # PII-flagged attributes are subject to encryption, masking, and audit policies
      # when the PII extension is enabled.
      #
      # @return [Boolean] true if this attribute holds PII data
      def pii?
        @pii
      end

      # Returns true if this attribute should appear in the web explorer
      # and generated UI (index tables, show pages, home cards).
      # Defaults to true. Set +visible: false+ in the DSL to suppress an attribute
      # from all UI surfaces while retaining it in the domain model.
      #
      #   attribute :password_digest, String, visible: false
      #
      # @return [Boolean] true if this attribute is visible in the UI
      def visible?
        @visible
      end

      # Returns true if this attribute stores a JSON blob.
      # JSON attributes are stored as unstructured data (Hash/Array) and
      # use the Ruby +JSON+ constant as their type marker.
      #
      # @return [Boolean] true if the type is JSON
      def json?
        type == JSON
      end

      # Returns the Ruby type name as a string for code generation.
      # Handles special cases: references become "String" (UUID), lists become
      # "Array", JSON stays "JSON", and all other types use their +to_s+ representation.
      #
      # @return [String] the Ruby type name suitable for generated source code
      #   (e.g., "String", "Integer", "Array", "JSON", "Address")
      def ruby_type
        if list?
          "Array"
        elsif json?
          "JSON"
        else
          type.to_s
        end
      end
    end
    end
  end
end
