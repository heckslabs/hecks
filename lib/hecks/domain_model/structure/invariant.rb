module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::Invariant
    #
    # A business rule that must always hold true for an aggregate or value object.
    # Invariants carry a human-readable message and an optional block that
    # evaluates the constraint at runtime.
    #
    # When a block is provided, it is evaluated in the context of the domain object
    # (via instance_exec). If the block returns false/nil, the invariant is violated
    # and the message is added to validation errors. When no block is provided, the
    # invariant serves as documentation only.
    #
    # Part of the DomainModel IR layer. Consumed by generators to produce
    # validation logic in domain gem classes.
    #
    #   inv = Invariant.new(message: "name is required", block: proc { !name.nil? })
    #   inv.message  # => "name is required"
    #   inv.block    # => #<Proc>
    #
    class Invariant
      # @return [String] a human-readable description of the business rule.
      #   Shown in validation error messages when the invariant is violated.
      attr_reader :message

      # @return [Proc, nil] an optional callable that evaluates the invariant.
      #   When present, it is evaluated via +instance_exec+ in the domain object's
      #   context and must return a truthy value for the invariant to hold.
      #   When nil, the invariant is documentation-only.
      attr_reader :block

      # Creates a new Invariant.
      #
      # @param message [String] human-readable description of the business rule
      #   (e.g., "quantity must be positive", "email must contain @")
      # @param block [Proc, nil] optional callable that returns truthy when the
      #   invariant holds and falsy when it is violated. Evaluated in the context
      #   of the domain object instance.
      #
      # @return [Invariant] a new Invariant instance
      def initialize(message:, block: nil)
        @message = message
        @block = block
      end
    end
    end
  end
end
