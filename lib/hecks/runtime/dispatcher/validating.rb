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
        # @param args [Hash{Symbol => Object}] the facts as flat keywords
        # @return [Runtime::Validation] the answer
        # @raise [Runtime::WiringError] if the verb names a port operation
        def validate(verb, **args)
          Validation.new(Collecting.collect { attempt_dry_run(verb, args) })
        end

        private

        def attempt_dry_run(verb, args)
          dry_run?(verb, **args)
        rescue Hecks::Refused => e
          Collecting.refuse(e)
        end
      end
    end
  end
end
