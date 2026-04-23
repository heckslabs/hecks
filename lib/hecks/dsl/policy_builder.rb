module Hecks
  module DSL

    # Hecks::DSL::PolicyBuilder
    #
    # DSL builder for reactive policy definitions. Binds an event name to a
    # trigger command, creating the wiring for event-driven workflows. Supports
    # an optional `condition` block that gates when the policy fires.
    #
    # Part of the DSL layer, nested under AggregateBuilder. Policies enable
    # cross-context communication by reacting to events from any context.
    #
    #   builder = PolicyBuilder.new("FraudAlert")
    #   builder.on "Withdrew"
    #   builder.trigger "FlagSuspicious"
    #   builder.condition { |event| event.amount > 10_000 }
    #   policy = builder.build  # => #<Policy name="FraudAlert" condition=... ...>
    #
    # Builds a BluebookModel::Behavior::Policy from reactive policy declarations.
    #
    # PolicyBuilder wires domain events to command triggers, forming the backbone
    # of event-driven cross-aggregate workflows. Each policy listens for a
    # specific event (+on+), dispatches a command (+trigger+) in response, and
    # optionally:
    # - Maps event attributes to command attributes (+map+)
    # - Injects static default values (+defaults+)
    # - Gates firing on a condition block (+condition+)
    # - Runs asynchronously (+async+)
    #
    # The +#build+ method validates that both +on+ and +trigger+ have been
    # called, raising descriptive errors if either is missing.
    class PolicyBuilder
      Behavior = BluebookModel::Behavior

      include Describable

      # Initialize a new policy builder with the given policy name.
      #
      # @param name [String] the policy name (e.g. "FraudAlert", "DisburseFunds")
      def initialize(name)
        @name = name
        @event_name = nil
        @trigger_command = nil
        @target_domain = nil
        @async = false
        @attribute_map = {}
        @condition = nil
        @defaults = {}
      end

      # Set the event this policy reacts to.
      #
      # @param event_name [String] the domain event name (e.g. "Withdrew", "CreatedLoan")
      # @return [void]
      def on(event_name)
        @event_name = event_name
      end

      # Set the command this policy triggers in response to the event.
      #
      # @param command_name [String] the command to dispatch (e.g. "FlagSuspicious")
      # @return [void]
      def trigger(command_name)
        @trigger_command = command_name
      end

      # Set the target domain for cross-domain policies.
      #
      # When a policy triggers a command in another domain, use +across+ to
      # declare the target. The validator will skip local command checks for
      # cross-domain triggers.
      #
      # @param domain_name [String] the target domain (e.g. "Dream", "StatusBar")
      # @return [void]
      def across(domain_name)
        @target_domain = domain_name
      end

      # Accept-and-ignore: some legacy nursery bluebooks mark cross-domain
      # policies via `cross_domain true` inside the `policy` block. Rust's
      # line-scanner silently skips the line; we do the same so parity
      # passes. The canonical way to declare cross-domain targets is
      # `across "TargetDomain"`.
      def cross_domain(*_args, **_kwargs, &_block)
        # no-op — canonical form is `across "Domain"`
      end

      # Set whether this policy runs asynchronously.
      #
      # Async policies are enqueued for background processing rather than
      # executed inline during event dispatch.
      #
      # @param flag [Boolean] true for async execution, false for sync (default: true)
      # @return [void]
      def async(flag = true)
        @async = flag
      end

      # Map event attributes to command attributes.
      #
      # When the triggered command expects different attribute names than the
      # event provides, use +map+ to define the translation. Keys are event
      # attribute names, values are command attribute names.
      #
      # @param mapping [Hash{Symbol => Symbol}] event attribute to command attribute mapping
      # @return [void]
      #
      # @example
      #   map principal: :amount, account_id: :account_id
      def map(**mapping)
        @attribute_map.merge!(mapping)
      end

      # Inject static values into the triggered command alongside mapped attrs.
      #
      # Defaults are merged into the command attributes on every trigger,
      # providing fixed values that don't come from the event.
      #
      # @param hash [Hash{Symbol => Object}] static attribute values
      # @return [void]
      #
      # @example
      #   defaults entity_type: "AiModel", action: "registered"
      def defaults(**hash)
        @defaults.merge!(hash)
      end

      # Set an anti-corruption translation block for cross-context policies.
      #
      # When a translate block is set, the policy calls it with the event
      # and uses the returned hash as the command attributes instead of
      # extracting/mapping from the event directly.
      #
      # @yield [event] block that transforms event data for the target context
      # @yieldparam event [Object] the domain event that triggered the policy
      # @yieldreturn [Hash{Symbol => Object}] attributes for the triggered command
      # @return [void]
      #
      # @example
      #   translate { |event| { item_name: event.name, price: 12.99 } }
      def translate(&block)
        @translate_block = block
      end

      # Set a conditional firing gate for this policy.
      #
      # When a condition is set, the policy only triggers the command if the
      # block returns true. The block receives the event object as its argument.
      #
      # @yield [event] block that determines whether to fire the policy
      # @yieldparam event [Object] the domain event that triggered the policy
      # @yieldreturn [Boolean] true to fire, false to skip
      # @return [void]
      #
      # @example
      #   condition { |event| event.amount > 10_000 }
      def condition(&block)
        @condition = block
      end

      # Build and return the BluebookModel::Behavior::Policy IR object.
      #
      # Validates that both +on+ (event name) and +trigger+ (command name) have
      # been specified. Raises with a descriptive message if either is missing.
      #
      # @return [BluebookModel::Behavior::Policy] the fully built policy IR object
      # @raise [RuntimeError] if +on+ or +trigger+ has not been called
      def build
        raise "Policy '#{@name}': missing 'on' (event name)" unless @event_name
        raise "Policy '#{@name}': missing 'trigger' (command name)" unless @trigger_command
        Behavior::Policy.new(
          name: @name,
          event_name: @event_name,
          trigger_command: @trigger_command,
          target_domain: @target_domain,
          async: @async,
          attribute_map: @attribute_map,
          condition: @condition,
          defaults: @defaults,
          translate: @translate_block,
          description: @description
        )
      end
    end
  end
end
