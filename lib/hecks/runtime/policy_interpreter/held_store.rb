require_relative "../errors"
require_relative "../reaction_notice"

module Hecks
  module Runtime
    class PolicyInterpreter
      # What a reaction records when another process held the store past the wait. It is neither
      # a refusal by the domain nor a defect in the code, so it fails no command: the command
      # that announced the event has saved. Mixed into {PolicyInterpreter}.
      module HeldStore
        private

        # Records the reaction as held and says so once on stderr.
        #
        # `unwritten:` is true only when the trigger's own write found the store held as it began
        # or committed (`StoreHeld`), so nothing of the reaction was saved and the outbox may run
        # it again. A held store met anywhere else leaves that unknown, and it is not run again.
        def held(policy, event, record, error)
          unwritten = error.is_a?(StoreHeld) && policy.for_each.to_s.empty?
          ReactionNotice.say "[hecks] reaction #{policy.name} on #{event.name} was held: the store was busy " \
                             "(#{error.message}). The command that announced #{event.name} is saved."
          record.merge(delivered: false, reason: error.message, held: true, unwritten: unwritten)
        end
      end
    end
  end
end
