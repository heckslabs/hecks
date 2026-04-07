module Hecksagon
  module Structure

    # Hecksagon::Structure::GateDefinition
    #
    # Represents a role-based access control gate for an aggregate. Gates restrict
    # which operations a given role can perform. When a gate is active, any
    # attempt to call a disallowed method raises an error.
    #
    #   gate = GateDefinition.new(aggregate: "Pizza", role: :admin, allowed_methods: [:find, :all, :create])
    #   gate.allows?(:find)    # => true
    #   gate.allows?(:delete)  # => false
    #
    class GateDefinition
      # @return [String] the aggregate this gate applies to
      attr_reader :aggregate

      # @return [Symbol] the role name (e.g., :admin, :guest, :customer)
      attr_reader :role

      # @return [Array<Symbol>] methods this role is allowed to call
      attr_reader :allowed_methods

      # @return [Symbol, nil] the aggregate attribute used for ownership checks
      attr_reader :ownership_field

      def initialize(aggregate:, role:, allowed_methods:, ownership_field: nil)
        @aggregate = aggregate.to_s
        @role = role.to_sym
        @allowed_methods = allowed_methods.map(&:to_sym)
        @ownership_field = ownership_field&.to_sym
      end

      # Returns true if the given method is allowed through this gate.
      def allows?(method_name)
        @allowed_methods.include?(method_name.to_sym)
      end
    end
  end
end
