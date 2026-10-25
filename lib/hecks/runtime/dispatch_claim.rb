module Hecks
  module Runtime
    # The identity of one saga dispatch, and the capability a repository needs to dedupe by it.
    #
    # A saga leg stamps each command it dispatches with a key naming the saga instance, the event
    # that moved it, the leg's trigger and the dispatch's position. A repository that declares
    # `:dispatch_claims` records the key in the same transaction as the write it guards
    # (`dispatch_claim`) and answers whether a key was applied (`dispatch_applied?`), so delivering
    # the same dispatch again changes nothing, whatever the command does.
    module DispatchClaim
      CAPABILITY = :dispatch_claims

      module_function

      # @param process_manager [String] the saga's declared name
      # @param correlation [String] the saga instance's correlation value
      # @param trigger [String] the event name, or `REFUSED`, that selected the leg
      # @param event [Runtime::Event] the event that moved the leg
      # @param index [Integer] the dispatch's position within the leg
      # @return [String] the key, stable across a crash because it is built from the leg's own event
      def key(process_manager:, correlation:, trigger:, event:, index:)
        [process_manager, correlation, trigger, event.name, event.id, event.occurred_at, index].join("/")
      end

      # @param repository [#capabilities] the repository a command saves through
      # @return [Boolean] whether it dedupes dispatches by key
      def supported?(repository) = repository.capabilities.include?(CAPABILITY)

      # What an interpreter does with a dispatch key: read it before any step, claim it inside the
      # save's transaction. Mixed into {Interpreting}; the context carries `dispatch_key`.
      module Claiming
        private

        # The steps from `save` onward, run only if this delivery wins the dispatch's claim; a
        # delivery that lost it applies nothing and answers with no events.
        def run_transactional_steps(steps, ctx)
          unless dispatch_claimed?(ctx)
            ctx.result = []
            return
          end

          steps.each { |name| send(:"step_#{name}", ctx) }
          enqueue_outbox(ctx)
        end

        # Whether the dispatch may go on: it carries no key, its repository dedupes none, or the
        # key was new and is now claimed in this transaction. False means another delivery of the
        # same dispatch got there first, so nothing is applied.
        def dispatch_claimed?(ctx)
          return true unless keyed_dispatch?(ctx)

          ctx.repository.dispatch_claim(ctx.dispatch_key)
        end

        # Whether a saga dispatch with this key was already applied, read before any step runs so a
        # guard the first delivery changed cannot refuse the second.
        def dispatch_applied?(ctx)
          keyed_dispatch?(ctx) && ctx.repository.dispatch_applied?(ctx.dispatch_key)
        end

        # What a command answers when its dispatch was already applied: no record, no events, and
        # nothing for the reaction layer to do.
        def already_applied(ctx) = [nil, [], ctx.plan, nil, []]

        def keyed_dispatch?(ctx)
          ctx.respond_to?(:dispatch_key) && ctx.dispatch_key && !ctx.dry_run && ctx.repository &&
            DispatchClaim.supported?(ctx.repository)
        end
      end
    end
  end
end
