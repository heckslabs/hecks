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

        # Never a creating command — a port operation always acts on an
        # aggregate that already exists (`operation.to`/`identity_attribute`
        # both name where its receiver comes from, never a birth). Answered
        # explicitly, not derived from `references` the way `Command
        # #creates?` is (`references.nil?` would read every operation as
        # creating, since `references` above is unconditionally nil) —
        # needed so `ReactionInvocation#source_receiver_for` can call
        # `target.command.creates?` on a port operation the same way it
        # already does on an ordinary command, and correctly lift a
        # same-aggregate policy's own Event.id as the operation's receiver.
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

        # The same reading `Command#addressing_key_for` gives, minus its
        # self-addressing branch — a port operation's `references` is
        # unconditionally nil (above), so it never means "this verb is
        # declared on the very aggregate it acts on" the way a command's
        # does; a port operation's only path back to its owner is a real,
        # declared reference-typed attribute, which is exactly what
        # `identity_attribute` already finds. Needed for the identical
        # reason `Command#addressing_key_for` is: `ReactionInvocation
        # #aggregate_aliases` calls it on whatever `target.command` holds,
        # a `PortOperation` now included since a policy can trigger one.
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
      end
    end
  end
end
