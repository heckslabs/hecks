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
