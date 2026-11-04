# frozen_string_literal: true

module Hecks
  module Runtime
    class Dispatcher
      # The nested dispatch a policy or saga reaction makes: one level deeper in the cascade, or,
      # for a policy declared `root`, starting the cascade over at depth zero.
      module RootReentry
        # Dispatches a reaction's command one level deeper in the cascade, as the system.
        #
        # The ambient caller is cleared (Runtime::Caller.without) so the triggering caller's role
        # neither satisfies nor blocks the reaction. Depth lives in `Thread.current`, not an ivar or
        # Mutex: the dispatcher is shared across threads. The reacting interpreter checks the limit.
        #
        # @param verb [String] the fully qualified verb of the reaction's target command
        # @param saga_correlation [Hash{String => Object}, nil] set when a saga leg dispatches
        # @param dispatch_key [String, nil] the saga dispatch's identity (`DispatchClaim.key`)
        # @param args [Hash{Symbol => Object}] flat facts, as `dispatch_flat` reads them
        # @return [Runtime::Dispatcher::Result] the nested dispatch's result
        # @raise [StandardError] any `Runtime::DOMAIN_REFUSALS` class; interpreters rescue these
        def reenter(verb, saga_correlation: nil, dispatch_key: nil, **args)
          at_depth(Thread.current[:hecks_reaction_depth].to_i + 1) do
            reaction_flat(verb, saga_correlation, dispatch_key, args)
          end
        end

        # Like `reenter`, but the reaction starts at depth zero: it is not counted toward the cap,
        # and the cascade's depth is restored when it returns. Only a `root` policy uses it.
        #
        # @param verb [String] the fully qualified verb of the reaction's target command
        # @param saga_correlation [Hash{String => Object}, nil] set when a saga leg dispatches
        # @param dispatch_key [String, nil] the saga dispatch's identity
        # @param args [Hash{Symbol => Object}] flat facts, as `dispatch_flat` reads them
        # @return [Runtime::Dispatcher::Result] the nested dispatch's result
        def reenter_root(verb, saga_correlation: nil, dispatch_key: nil, **args)
          at_depth(0) { reaction_flat(verb, saga_correlation, dispatch_key, args) }
        end

        private

        def at_depth(depth)
          previous = Thread.current[:hecks_reaction_depth].to_i
          Thread.current[:hecks_reaction_depth] = depth
          yield
        ensure
          Thread.current[:hecks_reaction_depth] = previous
        end

        def reaction_flat(verb, saga_correlation, dispatch_key, args)
          Caller.without do
            dispatch_flat(verb, args.merge(saga_correlation: saga_correlation, dispatch_key: dispatch_key))
          end
        end
      end
    end
  end
end
