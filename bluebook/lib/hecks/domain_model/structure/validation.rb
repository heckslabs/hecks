module Hecks
  module BluebookModel
    module Structure

    # Hecks::BluebookModel::Structure::Validation
    #
    # A validation rule for an aggregate attribute. Supports presence checks,
    # type constraints, and uniqueness enforcement. Rules are stored as a hash
    # (e.g. +{ presence: true, type: String, uniqueness: true }+).
    #
    # Validations are distinct from invariants: validations check individual
    # attributes against simple rules (present? correct type? unique?), while
    # invariants enforce cross-attribute business rules with custom logic.
    #
    # Part of the BluebookModel IR layer. Built by the DSL validation helpers and
    # consumed by generators to produce attribute validation logic.
    #
    #   v = Validation.new(field: :name, rules: { presence: true, type: String })
    #   v.presence?    # => true
    #   v.type_rule    # => String
    #   v.uniqueness?  # => false
    #
    class Validation
      # @return [Symbol] the attribute name this validation applies to (e.g., :name, :email, :status)
      attr_reader :field

      # @return [Hash] the validation rules as a Hash. Supported keys:
      #   - +:presence+ [Boolean] -- if true, the field must not be nil/empty
      #   - +:type+ [Class] -- the expected Ruby class (e.g., String, Integer)
      #   - +:uniqueness+ [Boolean] -- if true, the field value must be unique across all instances
      attr_reader :rules

      # Creates a new Validation.
      #
      # @param field [Symbol, String] the attribute name to validate. Converted to Symbol via +to_sym+.
      # @param rules [Hash] the validation rules. Supported keys are +:presence+ (Boolean),
      #   +:type+ (Class), and +:uniqueness+ (Boolean).
      #
      # @return [Validation] a new Validation instance
      def initialize(field:, rules:)
        @field = field.to_sym
        @rules = rules
      end

      # Returns whether this validation requires the field to be present (non-nil, non-empty).
      #
      # @return [Boolean, nil] true if presence is required, nil/false otherwise
      def presence?
        rules[:presence]
      end

      # Returns the expected type class for this field, if a type constraint is defined.
      #
      # @return [Class, nil] the expected Ruby class (e.g., String, Integer), or nil
      #   if no type constraint is set
      def type_rule
        rules[:type]
      end

      # Returns whether this validation enforces uniqueness for the field value
      # across all instances of the aggregate.
      #
      # @return [Boolean] true if uniqueness is enforced, false otherwise
      def uniqueness?
        !!rules[:uniqueness]
      end
    end
    end
  end
end
