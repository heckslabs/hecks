require_relative "../reaction_invocation"

module Hecks
  module Runtime
    class PolicyInterpreter
      # What a policy's trigger is given: the event payload or its `with:` projection, the
      # emitting record's identity, and the invocation the entry point re-enters with. Mixed into
      # {PolicyInterpreter}.
      module Arguments
        private

        # What the trigger is given: the whole event payload verbatim when no `with:` is
        # declared, otherwise the projection (a Symbol names a payload field, anything else
        # is a literal). `extra` is a fan-out's row key, merged into the source before the
        # projection so a `with:` can name the row it acts on. `row` is the fan-out row itself:
        # its fields are offered to a projection only, below the emitter identity and the
        # payload, and never reach an unprojected payload. `target` is the trigger's verb, which
        # decides whether the emitter's identity is lent to it (see {#lend_emitter_reference}).
        def trigger_args(policy, event, target, extra = {}, row = {})
          payload = event.payload.transform_keys(&:to_sym).merge(extra)
          args = if ReactionInvocation.projection_declared?(policy)
                   source = emitter_id(event).merge(row.transform_keys(&:to_sym))
                                             .merge(emitter_identity(event)).merge(payload)
                   projected_args(policy, event, source)
                 else
                   payload
                 end
          lend_emitter_reference(target, args, event)
        end

        # A trigger whose command takes a `reference_to` the emitting aggregate is lent the
        # emitter's identity under that reference's name, because an event's payload need not carry
        # the emitting record (a command with no attributes emits an empty payload). A value already
        # passed is never overridden, and a command with no such reference is left alone.
        def lend_emitter_reference(target, args, event)
          return args if event.id.to_s.empty?

          name = emitter_reference_name(target, event)
          return args if name.nil? || args.key?(name)

          args.merge(name => event.id)
        end

        # The attribute of the target command that references the emitting aggregate, or nil when
        # the target is unknown here (its refusal is raised later, with its canonical wording).
        def emitter_reference_name(target, event)
          command = declared_command(target)
          return nil unless command

          reference = command.attributes.find { |attribute| attribute.reference? && references_emitter?(attribute, event) }
          reference&.name&.to_sym
        end

        def references_emitter?(attribute, event)
          attribute.target_name.to_s == emitter_aggregate_name(event)
        end

        # The emitting aggregate's bare name, without its domain.
        def emitter_aggregate_name(event)
          _domain, bare_name = event.aggregate.to_s.split("::", 2)
          bare_name || event.aggregate.to_s
        end

        # The declared command `target` names, or nil when no bluebook declares it.
        def declared_command(target)
          domain, aggregate_name, command_name = Naming.split_verb(target)
          @registry.bluebook(domain)&.aggregate(aggregate_name)&.command(command_name)
        end

        # The emitting record's whole identity as `:id`, below everything else: a fan-out row
        # carries its own `id`, and a payload field of that name wins (ADR 0153).
        def emitter_id(event)
          event.id.nil? || event.id.to_s.empty? ? {} : { id: event.id }
        end

        def projected_args(policy, event, payload)
          args = ReactionInvocation.resolve_mapping(
            with_spec: policy.with_spec,
            scopes:    [["event payload and fan-out row", payload]],
            label:     "#{policy.name}'s trigger"
          )

          # Raw inputs kept for Properties.dispatch_binding_fidelity's re-derivation.
          @registry.policy_dispatch_log << { policy: policy.name, on: event.name, payload: payload,
                                              with_spec: policy.with_spec, args: args }
          args
        end

        # The emitting record's identity, offered to an explicit `with:` projection under
        # the emitting aggregate's identity heads (never over a payload value). Without it
        # a cross-aggregate reaction cannot say which record to address. The build-time
        # validator admits the same names (`BluebookBuilder.check_with_spec!`).
        def emitter_identity(event)
          return {} if event.id.nil? || event.id.to_s.empty?

          construct = emitting_construct(event)
          return {} unless construct

          construct.identity_heads.to_h { |head| [head.to_sym, event.id] }
        end

        # The aggregate that emitted `event`, when its bluebook is loaded.
        def emitting_construct(event)
          domain, bare_name = event.aggregate.to_s.split("::", 2)
          bare_name && @registry.bluebook(domain)&.aggregate(bare_name)
        end

        def reaction_invocation(target, args, policy, event)
          ReactionInvocation.build(
            registry:        @registry,
            verb:            target,
            projected:       args,
            explicit:        ReactionInvocation.projection_declared?(policy),
            source_receiver: { aggregate: event.aggregate, identity: event.id }
          )
        end
      end
    end
  end
end
