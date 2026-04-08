require "date"

module Hecks
  module DSL

    # Hecks::DSL::AttributeCollector
    #
    # Shared mixin for DSL builders that collect attributes. Provides the
    # `attribute` and `list_of` DSL methods. Included by AggregateBuilder,
    # CommandBuilder, ValueObjectBuilder, and BluebookBuilder.
    #
    #   attribute :name, String
    #   attribute :toppings, list_of("Topping")
    #
    # Mixin that provides attribute declaration DSL methods to builders.
    #
    # Any builder class that includes this module gains the +attribute+ and
    # +list_of+ methods, plus automatic type resolution from symbols/strings
    # to Ruby classes via +TYPE_MAP+.
    #
    # Including classes must initialize an +@attributes+ instance variable
    # (typically an empty Array) before these methods are called.
    module AttributeCollector
      # Maps symbolic type shorthand names to Ruby classes.
      # Supports both full names (:string, :integer) and abbreviations (:str, :int).
      #
      # @return [Hash{Symbol => Class}] frozen mapping of type aliases to Ruby classes
      TYPE_MAP = {
        string: String, str: String,
        integer: Integer, int: Integer,
        float: Float,
        boolean: TrueClass, bool: TrueClass,
        symbol: Symbol, sym: Symbol,
        array: Array,
        hash: Hash,
        date: Date,
        datetime: DateTime,
      }.freeze

      # Declare an attribute on the current builder.
      #
      # The type can be a Ruby class (String, Integer), a symbol shorthand
      # (:string, :int), a string ("String"), or a wrapper hash from +list_of+.
      # Additional keyword options (e.g. +default:+, +optional:+, +enum:+) are
      # passed through to the Attribute constructor.
      #
      # @param name [Symbol] the attribute name
      # @param type [Class, Symbol, String, Hash] the attribute type or type wrapper
      # @param options [Hash] additional options passed to Attribute.new
      #   (e.g. +default:+, +optional:+, +enum:+)
      # @return [void]
      def attribute(name = nil, type = nil, **options, &block)
        if name.nil?
          name = :unnamed
          type ||= String
        elsif type.nil?
          type = String
        end
        type = resolve_type(type)
        list = type.is_a?(Hash) && type[:list]
        actual_type = type.is_a?(Hash) ? type.values.first : type

        @attributes << BluebookModel::Structure::Attribute.new(
          name: name,
          type: actual_type,
          list: !!list,
          **options
        )

        # Block on attribute declares lifecycle transitions on this field
        if block && respond_to?(:lifecycle, true)
          lifecycle(name, default: (options[:default] || "").to_s, &block)
        end
      end

      # Create a list-type wrapper for use with +attribute+.
      #
      # Returns a hash that +attribute+ recognizes as a list collection type.
      #
      # @param type [Class, String] the element type of the list
      # @return [Hash{Symbol => Class|String}] a wrapper hash with key +:list+
      #
      # @example
      #   attribute :toppings, list_of("Topping")
      def list_of(type)
        { list: type }
      end

      private

      # Resolve a type argument to its canonical form.
      #
      # Symbols and strings are looked up in +TYPE_MAP+. If no mapping is
      # found, the original value is returned as-is (supporting custom type
      # names like "Topping" that refer to value objects or entities).
      #
      # @param type [Class, Symbol, String, Hash] the raw type argument
      # @return [Class, String, Hash] the resolved type
      def resolve_type(type)
        case type
        when Symbol then TYPE_MAP.fetch(type) { type }
        when String then TYPE_MAP.fetch(type.downcase.to_sym) { type }
        else type
        end
      end
    end
  end
end
