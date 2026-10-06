# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module EvolveRun
      # The lifecycle of a keyword's argument: `argument-propose`, `argument-admit`,
      # `argument-deprecate` and `argument-retire`.
      module Arguments
        # @return [Boolean] whether the gates held
        def propose_argument(args, evolve, root)
          keyword = args.shift or abort "argument-propose which keyword's argument?"
          context = evolve.option(args, "context") or abort "--context is required"
          kind = evolve.option(args, "kind") or abort "--kind is required — text|symbol|number|flag|literal|constant|pairs|list"
          ok = guarded("#{keyword} argument", context, evolve, root) do
            evolve.propose_argument(keyword: keyword, context: context, kind: kind, **argument_options(args, evolve))
          end
          puts_argument_proposed(context, keyword) if ok
          ok
        end

        # @return [Boolean] whether the gates held
        def set_argument_status(command, args, evolve, root)
          keyword = args.shift or abort "#{command} which keyword's argument?"
          context = evolve.option(args, "context") or abort "--context is required"
          guarded("#{keyword} argument", context, evolve, root) do
            evolve.set_argument_status(keyword: keyword, context: context, to: ARGUMENT_STATUS.fetch(command),
                                       at: evolve.option(args, "at", ""), named: evolve.option(args, "named", ""))
          end
        end

        private

        def argument_options(args, evolve)
          { required: evolve.option(args, "required", "false"),
            at: evolve.option(args, "at", ""), named: evolve.option(args, "named", ""),
            fills: evolve.option(args, "fills", ""),
            pairs_shape: evolve.option(args, "pairs-shape") }
        end

        def puts_argument_proposed(context, keyword)
          puts "Proposed. It reaches no projection until admitted. Before `hecks evolve argument-admit`:"
          puts "  1. teach the #{context} builder's #{keyword} method the argument"
        end
      end
    end
  end
end
