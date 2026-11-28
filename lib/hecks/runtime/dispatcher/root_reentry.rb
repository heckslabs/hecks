# frozen_string_literal: true

require_relative "../caller"
require_relative "../role_shadow"

module Hecks
  module Runtime
    class Dispatcher
      # The nested dispatch a policy or saga reaction makes: one level deeper in the cascade, or,
      # for a policy declared `root`, starting the cascade over at depth zero.
      module RootReentry
        # Dispatches a reaction's command one level deeper in the cascade. The triggering caller
        # is cleared (`Caller.without`), then a policy's reaction is bound as `Caller.reacting_as`
        # says (ADR 0216); a saga leg runs with no caller. Depth lives in `Thread.current`, since
        # the dispatcher is shared across threads; the reacting interpreter checks the limit.
        #
        # @param verb [String] the fully qualified verb of the reaction's target command
        # @param saga_correlation [Hash{String => Object}, nil] set when a saga leg dispatches
        # @param dispatch_key [String, nil] the saga dispatch's identity (`DispatchClaim.key`)
        # @param reaction [Bluebook::Policy, nil] the policy whose reaction this is; nil for a saga
        # @param args [Hash{Symbol => Object}] flat facts, as `dispatch_flat` reads them
        # @return [Runtime::Dispatcher::Result] the nested dispatch's result
        # @raise [StandardError] any `Runtime::DOMAIN_REFUSALS` class; interpreters rescue these
        def reenter(verb, saga_correlation: nil, dispatch_key: nil, reaction: nil, **args)
          at_depth(Thread.current[:hecks_reaction_depth].to_i + 1) do
            reaction_flat(verb, saga_correlation, dispatch_key, reaction, args)
          end
        end

        # Like `reenter`, but the reaction starts at depth zero: it is not counted toward the cap,
        # and the cascade's depth is restored when it returns. Only a `root` policy uses it.
        #
        # @param verb [String] the fully qualified verb of the reaction's target command
        # @param saga_correlation [Hash{String => Object}, nil] set when a saga leg dispatches
        # @param dispatch_key [String, nil] the saga dispatch's identity
        # @param reaction [Bluebook::Policy, nil] the policy whose reaction this is
        # @param args [Hash{Symbol => Object}] flat facts, as `dispatch_flat` reads them
        # @return [Runtime::Dispatcher::Result] the nested dispatch's result
        def reenter_root(verb, saga_correlation: nil, dispatch_key: nil, reaction: nil, **args)
          at_depth(0) { reaction_flat(verb, saga_correlation, dispatch_key, reaction, args) }
        end

        private

        def at_depth(depth)
          previous = Thread.current[:hecks_reaction_depth].to_i
          Thread.current[:hecks_reaction_depth] = depth
          yield
        ensure
          Thread.current[:hecks_reaction_depth] = previous
        end

        def reaction_flat(verb, saga_correlation, dispatch_key, reaction, args)
          Caller.without(reacting: true) do
            bound_as(reaction) do
              dispatch_flat(verb, args.merge(saga_correlation: saga_correlation, dispatch_key: dispatch_key))
            end
          end
        end

        # Binds a policy's reaction as `Caller.reacting_as` says. A saga leg runs as it is, and so
        # does an ask that declares no `acts_as`: a port operation takes no role, and the adapter
        # behind it acts for the process.
        def bound_as(reaction, &)
          return yield unless reaction
          return yield if reaction.asks? && reaction.acts_as.nil?

          Caller.reacting_as(reaction.acts_as, enforcing: RoleShadow.enforcing?, &)
        end
      end
    end
  end
end
