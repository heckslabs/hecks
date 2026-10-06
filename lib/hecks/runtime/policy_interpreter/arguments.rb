require_relative "../reaction_invocation"

module Hecks
  module Runtime
    class PolicyInterpreter
      # What a policy's trigger is given: the event payload or its `with:` projection, the
      # emitting record's identity, and the invocation the door re-enters with. Mixed into
      # {PolicyInterpreter}.
      module Arguments
        private

        # What the trigger is given: the whole event payload verbatim when no `with:` is
        # declared, otherwise the projection (a Symbol names a payload field, anything else
        # is a literal). `extra` is a fan-out's row key, merged into the source before the
        # projection so a `with:` can name the row it acts on.
        def trigger_args(policy, event, extra = {})
          payload = event.payload.transform_keys(&:to_sym).merge(extra)
          return payload unless ReactionInvocation.projection_declared?(policy)

          projected_args(policy, event, emitter_identity(event).merge(payload))
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
