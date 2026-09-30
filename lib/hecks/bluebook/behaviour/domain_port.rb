require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # **What one port operation does**.
      module PortOperation
        include Indexed

        # An operation declares no reference of its own — the owner is
        # what it acts for, and `identity_attribute` is how that is found.
        #
        # @return [nil] always `nil`
        def references = nil

        # A port operation always acts on an existing aggregate. Answered explicitly
        # because `references.nil?` would read every operation as creating.
        #
        # @return [Boolean] always `false`
        def creates? = false

        # Finds the reference-typed attribute through which this operation addresses
        # its owning aggregate.
        #
        # @param owner_name [String, Symbol] the owning aggregate's name
        # @return [Bluebook::Attribute, nil] the reference-typed attribute targeting
        #   `owner_name`, or `nil` if this operation declares none
        def identity_attribute(owner_name)
          @attributes.find { |attribute| attribute.reference? && attribute.type.target_name == owner_name.to_s }
        end

        # Like `Command#addressing_key_for` without the self-addressing branch: the
        # reference attribute is the only path back to the owner.
        #
        # @param aggregate_name [String, Symbol] the name of the aggregate a row of which
        #   would address this operation
        # @return [Symbol, nil] the reference-typed attribute's name a caller passes to
        #   address that row, or `nil` if this operation cannot be addressed by one
        def addressing_key_for(aggregate_name) = identity_attribute(aggregate_name)&.name
      end

      # **What a port does** — one finder over its declared operations.
      module DomainPort
        # Finds a declared operation by name.
        #
        # @param named [String, Symbol] the operation's declared name
        # @return [Bluebook::PortOperation, nil] the operation, or `nil` if none is
        #   declared by that name
        def operation(named) = @operations.find { |op| op.hecks_name == named.to_s }

        # Finds the binding this port gives a query, if it answers that query.
        #
        # @param named [String, Symbol] the query's declared name
        # @return [Bluebook::QueryAnswer, nil] the binding, or `nil` if this port does not
        #   answer that query
        def answer_for(named) = @answered_queries.find { |answer| answer.name == named.to_s }
      end
    end
  end
end
