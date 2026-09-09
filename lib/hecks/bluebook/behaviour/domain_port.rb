require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # WHAT ONE PORT OPERATION DOES.
      module PortOperation
        include Indexed

        # An operation declares no reference of its own — the OWNER is
        # what it acts for, and `identity_attribute` is how that is found.
        def references = nil

        # NEVER a creating command — a port operation always acts on an
        # aggregate that already exists (`operation.to`/`identity_attribute`
        # both name where its RECEIVER comes from, never a birth). Answered
        # explicitly, not derived from `references` the way `Command
        # #creates?` is (`references.nil?` would read every operation as
        # creating, since `references` above is unconditionally nil) —
        # needed so `ReactionInvocation#source_receiver_for` can call
        # `target.command.creates?` on a port operation the same way it
        # already does on an ordinary command, and correctly lift a
        # same-aggregate policy's own Event.id as the operation's receiver.
        def creates? = false

        def identity_attribute(owner_name)
          @attributes.find { |attribute| attribute.reference? && attribute.type.target_name == owner_name.to_s }
        end

        # THE SAME READING `Command#addressing_key_for` gives, minus its
        # self-addressing branch — a port operation's `references` is
        # unconditionally nil (above), so it never means "this verb is
        # declared ON the very aggregate it acts on" the way a command's
        # does; a port operation's only path back to its owner is a real,
        # declared reference-typed attribute, which is exactly what
        # `identity_attribute` already finds. Needed for the identical
        # reason `Command#addressing_key_for` is: `ReactionInvocation
        # #aggregate_aliases` calls it on whatever `target.command` holds,
        # a `PortOperation` now included since a policy can trigger one.
        def addressing_key_for(aggregate_name) = identity_attribute(aggregate_name)&.name
      end

      # WHAT A PORT DOES — one finder over its declared operations.
      module DomainPort
        def operation(named) = @operations.find { |op| op.hecks_name == named.to_s }
      end
    end
  end
end
