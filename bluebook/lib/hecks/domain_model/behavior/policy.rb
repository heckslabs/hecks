module Hecks
  module DomainModel
    module Behavior

    # Hecks::DomainModel::Behavior::Policy
    #
    # Intermediate representation of a domain policy. Policies come in two forms:
    #
    # 1. *Reactive policies* trigger a command in response to an event (cross-context
    #    communication). They listen for a named event and dispatch a command when
    #    fired. An optional +condition+ block can gate whether the policy fires,
    #    and an +attribute_map+ can transform event data into command attributes.
    #    The +defaults+ hash provides fallback values for command attributes not
    #    present on the event.
    #
    # 2. *Guard policies* carry a block that validates a command before execution.
    #    If the block returns falsy, the command is rejected.
    #
    # Part of the DomainModel IR layer. Built by PolicyBuilder (reactive) or
    # AggregateBuilder (guard), consumed by generators and the Application layer.
    # Use {#reactive?} and {#guard?} to distinguish the two forms.
    #
    #   # Reactive policy: event -> command (conditional)
    #   policy = Policy.new(name: "FraudAlert", event_name: "Withdrew",
    #                       trigger_command: "FlagSuspicious",
    #                       condition: ->(event) { event.amount > 10_000 })
    #   policy.reactive?   # => true
    #   policy.condition   # => #<Proc ...>
    #
    #   # Guard policy: block validates a command
    #   guard = Policy.new(name: "MustBeAdmin", block: ->(cmd) { cmd.role == "admin" })
    #   guard.guard?      # => true
    #   guard.reactive?   # => false
    #
    class Policy
      # @return [String] unique policy name (e.g. "FraudAlert", "MustBeAdmin")
      # @return [String, nil] event name that triggers this reactive policy, or nil for guards
      # @return [String, nil] command name to dispatch when a reactive policy fires
      # @return [Boolean] whether the reactive policy should fire asynchronously
      # @return [Proc, nil] guard block that receives a command and returns truthy/falsy,
      #   or nil for reactive policies
      # @return [Hash{Symbol => Symbol}] mapping of event attribute names to command
      #   attribute names for reactive policies (e.g. { amount: :transfer_amount })
      # @return [Proc, nil] optional condition block for reactive policies; receives the
      #   event and must return truthy for the policy to fire
      # @return [Hash{Symbol => Object}] default values for command attributes not present
      #   on the event when a reactive policy fires
      attr_reader :name, :event_name, :trigger_command, :async, :block, :attribute_map, :condition, :defaults, :description

      # Creates a new Policy IR node.
      #
      # @param name [String] unique policy name
      # @param event_name [String, nil] event name to listen for (reactive policies only)
      # @param trigger_command [String, nil] command to dispatch on event (reactive policies only)
      # @param async [Boolean] whether reactive dispatch is asynchronous. Defaults to false.
      # @param block [Proc, nil] guard validation block (guard policies only). Receives a
      #   command object and must return truthy for the command to proceed.
      # @param attribute_map [Hash{Symbol => Symbol}] maps event attributes to command
      #   attributes for reactive policies. Defaults to empty hash.
      # @param condition [Proc, nil] optional gating condition for reactive policies.
      #   Receives the event object; must return truthy for the policy to fire.
      # @param defaults [Hash{Symbol => Object}] fallback attribute values for the
      #   triggered command. Defaults to empty hash.
      # @return [Policy]
      def initialize(name:, event_name: nil, trigger_command: nil, async: false, block: nil, attribute_map: {}, condition: nil, defaults: {}, description: nil)
        @name = name
        @event_name = event_name && Names.event_name(event_name)
        @trigger_command = trigger_command && Names.command_name(trigger_command)
        @async = async
        @block = block
        @attribute_map = attribute_map
        @condition = condition
        @defaults = defaults
        @description = description
      end

      # Returns whether this policy is a guard policy (has a validation block).
      # Guard policies validate commands before execution; if the block returns
      # falsy, the command is rejected.
      #
      # @return [Boolean] true if this policy has a guard block
      def guard?
        block != nil
      end

      # Returns whether this policy is a reactive policy (listens for an event).
      # Reactive policies dispatch a command in response to a domain event,
      # optionally gated by a condition.
      #
      # @return [Boolean] true if this policy listens for an event
      def reactive?
        event_name != nil
      end
    end
    end
  end
end
