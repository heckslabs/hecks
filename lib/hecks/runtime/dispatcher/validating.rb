require_relative "../collecting"
require_relative "../validation"

module Hecks
  module Runtime
    class Dispatcher
      # Validation: a dry run that reports every reason a command would be refused.
      module Validating
        # Answers whether a command would be accepted right now, and if not, every reason.
        #
        # Runs the same pipeline as `dry_run?`, so nothing is saved, emitted or reacted to, but a
        # stage that refuses finishes before the run stops, and a rule that loops reports every
        # failure. The role is checked first and alone: a caller who may not run the command is told
        # only that, and nothing the other rules would reveal.
        #
        # @param verb [String] the fully qualified aggregate or entity command verb
        # @param args [Hash] the receiver and facts in one flat Hash, as `dispatch_flat` takes them:
        #   Symbol keys `:to` and `:with` route, every other key is a fact
        # @return [Runtime::Validation] the answer
        # @raise [Runtime::WiringError] if the verb names a port operation
        def validate(verb, args = {})
          call = flat_call(verb, args)
          Validation.new(Collecting.collect { attempt_dry_run(call) })
        end

        private

        def attempt_dry_run(call)
          dry_run_call(call)
        rescue Hecks::Refused => e
          Collecting.refuse(e)
        end
      end
    end
  end
end
