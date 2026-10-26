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
          validation_of(flat_call(verb, args))
        end

        # Answers `validate`'s question of the facts as `dry_run?` reads them.
        #
        # Every key is a fact, `to` and `with` included, never routing, so this asks exactly what
        # `dry_run?` was asked of the same keywords and differs only in reporting every reason.
        #
        # @param verb [String] the fully qualified aggregate or entity command verb
        # @param args [Hash{Symbol => Object}] the facts as flat keywords, as `dry_run?` takes them
        # @return [Runtime::Validation] the answer
        # @raise [Runtime::WiringError] if the verb names a port operation
        def validate_facts(verb, **args)
          validation_of(Routing::Call.new(verb: verb, flat: args))
        end

        # Answers whether a record's lifecycle state lets a command run, reading no argument: the
        # command's own `from:` guard and the aggregate's transitions, as the dispatch decides them.
        #
        # `validate` stops at the arguments stage when an argument is missing, so a caller asking
        # what a record could do next, with no arguments yet, asks this as well.
        #
        # @param domain [String] the chapter's name
        # @param aggregate [Bluebook::Aggregate] the aggregate the record belongs to
        # @param command [Bluebook::Command] the command asked about
        # @param id [String] the record's identity
        # @return [Boolean] false when the state refuses the command
        def state_admits?(domain, aggregate, command, id)
          instance = registry.repository(domain, aggregate).find(id)
          rules = CommandRules.new(registry)
          rules.enforce_lifecycle_guard(aggregate, command, instance)
          rules.admissible_transition(aggregate, command, instance)
          true
        rescue LifecycleRefused
          false
        end

        private

        def validation_of(call)
          Validation.new(Collecting.collect { attempt_dry_run(call) })
        end

        def attempt_dry_run(call)
          dry_run_call(call)
        rescue Hecks::Refused => e
          Collecting.refuse(e)
        end
      end
    end
  end
end
