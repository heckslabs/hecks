module Hecks
  module Bluebook
    module ModelCheck
      # The check over a policy that hands its trigger the whole event. With no `with:`, the
      # trigger is given the event's payload verbatim (`PolicyInterpreter#trigger_args`), and a
      # command refuses any argument it does not take (`ArgumentGate#refuse_unknown_arguments`),
      # so a required payload field the target does not take refuses every reaction.
      module ForwardedPayloadChecks
        # Warns when a same-domain policy with no `with:` forwards an event that always carries
        # a field its target command does not take. A warning, not an error: a domain may keep
        # such a policy on purpose, as a fixture that pins the refusal itself.
        #
        # @param bluebook [Bluebook::Chapter] the chapter that declares `policy`
        # @param policy [Bluebook::Policy] a same-domain policy
        # @return [Finding, nil] a `:forwarded_payload` warning, or nil when every reaction could
        #   deliver, or the policy projects, asks, or targets an entity command
        def forwarded_payload_finding(bluebook, policy)
          aggregate, command = forwarded_target(bluebook, policy)
          return unless command

          refused = required_event_fields(bluebook, policy.on_event.to_s) - accepted_arguments(bluebook, aggregate, command)
          return if refused.empty?

          Finding.new(kind: :forwarded_payload, severity: :warning, subject: policy.name,
                      message: "has no with:, so #{policy.trigger_command} is given #{policy.on_event} whole, " \
                               "and does not take #{refused.map(&:inspect).join(", ")}; every reaction will be " \
                               "refused. Name what the trigger takes with with:")
        end

        # The aggregate and command a projection-less trigger dispatches, or nil. An entity
        # target is not judged: it also takes the identity heads of each hop it walks.
        def forwarded_target(bluebook, policy)
          owner, command_name = forwarding_trigger(policy)
          return unless command_name

          aggregate = bluebook.aggregates.find { |candidate| candidate.hecks_name == owner }
          command = aggregate&.commands&.find { |candidate| candidate.hecks_name == command_name }
          [aggregate, command] if command
        end

        # The owner and command name of a trigger given its event whole, or nil when the policy
        # projects, triggers nothing, or names an entity command (`"Owner.Entity.Command"`).
        def forwarding_trigger(policy)
          return unless policy.with_spec.to_a.empty? && policy.trigger_command

          owner, command_name = policy.trigger_command.to_s.split(".", 2)
          [owner, command_name] unless command_name.nil? || command_name.include?(".")
        end

        # The fields every instance of the event carries: its emitting command's required
        # attributes. A qualified name (`"Lot.LotRegraded"`) reads only that owner's commands.
        def required_event_fields(bluebook, event)
          owner, _, bare = event.rpartition(".")
          emitter = commands_of(bluebook, owner).find { |command| command.emits.include?(bare) }
          emitter ? emitter.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym } : []
        end

        def commands_of(bluebook, owner)
          head = owner.split(".").first
          owners = owner.empty? ? bluebook.aggregates : bluebook.aggregates.select { |a| a.hecks_name == head }
          owners.flat_map { |aggregate| aggregate.commands + aggregate.entities.flat_map(&:commands) }
        end

        # What the target accepts, as the runtime's argument gate reckons it: its attributes,
        # `id`, its aggregate's identity heads, its reference key and every saga correlation head.
        def accepted_arguments(bluebook, aggregate, command)
          reference = command.references.to_s.empty? ? nil : Naming.reference_key(command.references.to_s)
          [*command.attributes.map(&:name), :id, *aggregate.identity_heads, reference,
           *correlation_heads_of(bluebook)].compact.map(&:to_sym)
        end

        def correlation_heads_of(bluebook)
          bluebook.process_managers.filter_map { |saga| saga.correlates_by && saga.correlation_head }
        end
      end
    end
  end
end
