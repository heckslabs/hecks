require_relative "../../bluebook/expression/evaluator"
require_relative "../../rendering"
require_relative "../errors"

module Hecksagain
  module Runtime
    class CommandRules
      # Whether a command may run at all: its declared givens, and the
      # lifecycle transition it asks for.
      module Admissibility
        def enforce_givens(subject, command, args)
          command.givens.each do |given|
            next if Bluebook::Expression::Evaluator.call(given.canonical, subject, args)

            raise GivenNotMet, "#{command.hecks_name} refused — #{given.description}"
          end
        end

        # The far side of the contract: evaluated against the SETTLED record
        # — after mutations and the lifecycle move, before anything persists
        # — with `old` carrying the state as the givens saw it. Injected into
        # the attrs at evaluation time only; the payload gate never sees it.
        #
        # `old` — and every dispatch ARGUMENT — wins over a same-named STATE
        # field in expression scope (Resolver#fetch checks attrs first). An
        # ensures naming a field the command also takes as an argument (or,
        # on an entity, a field that doubles as the addressing argument
        # element_of reads) will read the ARGUMENT, not the settled value.
        # Not new to ensures — `given` lives under the same rule — but an
        # ensures is more likely to collide, since it typically re-reads a
        # field the command just took in to mutate it.
        def enforce_ensures(subject, command, args, old:)
          command.ensures.each do |rule|
            next if Bluebook::Expression::Evaluator.call(rule.canonical, subject, args.merge(old: old))

            raise EnsuresNotMet, "#{command.hecks_name} refused — #{rule.description}"
          end
        end

        def admissible_transition(declaring, command, subject)
          lifecycle = declaring.lifecycle
          return nil unless lifecycle

          candidates = lifecycle.transitions_for(command.hecks_name)
          return nil if candidates.empty?

          current  = subject[lifecycle.field].to_s
          admitted = candidates.find { |t| !t.constrained? || Array(t.from).include?(current) }
          return admitted if admitted

          allowed = candidates.flat_map { |t| Array(t.from) }.uniq
          raise LifecycleRefused,
                "#{command.hecks_name} refused — #{lifecycle.field} is #{Rendering.describe(current)}, and " \
                "#{command.hecks_name} moves it only from #{allowed.map(&:inspect).join(' or ')}"
        end
      end
    end
  end
end
