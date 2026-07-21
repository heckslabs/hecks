module Hecks
  module DSL

    # Hecks::DSL::ValueObjectBuilder
    #
    # DSL builder for value object definitions. Collects attributes and invariants,
    # then builds a BluebookModel::Structure::ValueObject. Used inside aggregate blocks.
    #
    # Part of the DSL layer, nested under AggregateBuilder. The resulting value
    # object is embedded within its parent aggregate.
    #
    #   builder = ValueObjectBuilder.new("Address")
    #   builder.attribute :street, String
    #   builder.attribute :city, String
    #   builder.invariant("street required") { !street.nil? }
    #   vo = builder.build  # => #<ValueObject name="Address" ...>
    #
    # Builds a BluebookModel::Structure::ValueObject from DSL declarations.
    #
    # ValueObjectBuilder collects attributes and invariants for an immutable,
    # equality-by-value type embedded within an aggregate. Value objects have
    # no identity of their own -- two value objects with the same attribute
    # values are considered equal. They are always immutable; changes produce
    # new instances.
    #
    # Includes AttributeCollector for the +attribute+, +list_of+, and
    # +reference_to+ DSL methods.
    class ValueObjectBuilder
      Structure = BluebookModel::Structure

      include AttributeCollector
      include Describable

      # Initialize a new value object builder with the given type name.
      #
      # @param name [String] the value object type name (e.g. "Address", "Money")
      def initialize(name)
        @name = name
        @attributes = []
        @invariants = []
        @derivations = []
        @members = []
      end

      # Declare this value object as a CLOSED SET of whole values
      # (GRAMMAR-one-of, 2026-07-19). Each +member+ inside the block is a
      # fully-specified instance ; the first attribute is the discriminant.
      #
      #   one_of do
      #     member code: "USD", symbol: "$",  minor_units: 2
      #     member code: "JPY", symbol: "¥", minor_units: 0
      #   end
      # Both spellings resolve here inside a VO body (this def shadows
      # the AttributeCollector mixin's scalar helper, so it must speak
      # both) : with a block it declares the closed member set ; with
      # values it is the scalar sugar passthrough used in attribute
      # position (`attribute :value, one_of("none", "drafting")`).
      def one_of(*values, &block)
        if block
          instance_eval(&block)
        else
          { enum: values.map(&:to_s) }
        end
      end

      # One member of the closed set — kwargs preserve declaration order,
      # which the canonical IR relies on for parity with the Rust parser.
      def member(**fields)
        @members << fields
      end

      # Define an invariant constraint on this value object.
      #
      # Invariants are boolean conditions that must always hold true for the
      # value object to be in a valid state. They are checked at construction.
      #
      # @param message [String] human-readable description of the invariant
      # @yield block that returns true when the invariant holds, false when violated
      # @return [void]
      def invariant(message, &block)
        @invariants << Structure::Invariant.new(message: message, block: block)
      end

      # Define a pure DERIVATION on this value object -- the behaviour half
      # of a rich VO (Evans : value objects are the core). A derivation is a
      # side-effect-free method over the VO's own fields + block params,
      # callable from a command's `given` or an invariant :
      #
      #   derive :zero?,   Boolean do cents == 0 end
      #   derive :covers?, Boolean do |other| cents >= other.cents end
      #   # given { balance.covers?(amount) }
      #
      # The param NAMES are read from the block's signature (`|other|` =>
      # ["other"]) ; a param's type is whatever binds at the call site. The
      # return type token drives evaluation (Boolean => predicate).
      #
      # @param name [Symbol, String] the method name (trailing "?" allowed)
      # @param return_type [Object] the return type token (e.g. Boolean) -- .to_s'd
      # @yield the pure body, evaluated over own-fields + bound params
      # @return [void]
      def derive(name, return_type, &block)
        params = block ? block.parameters.map { |_kind, pname| pname.to_s } : []
        @derivations << Structure::Derivation.new(
          name: name.to_s,
          return_type: return_type.to_s,
          params: params,
          block: block
        )
      end

      # Build and return the BluebookModel::Structure::ValueObject IR object.
      #
      # @return [BluebookModel::Structure::ValueObject] the fully built value object IR object
      def build
        Structure::ValueObject.new(
          name: @name,
          attributes: @attributes,
          invariants: @invariants,
          derivations: @derivations,
          description: @description,
          members: @members
        )
      end
    end
  end
end
