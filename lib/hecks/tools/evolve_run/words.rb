# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module EvolveRun
      # The lifecycle of a word: `propose`, `admit`, `deprecate`, `retire` and `rename`.
      module Words
        # @return [Boolean] whether the gates held
        def propose(args, evolve, root)
          word = args.shift or abort "propose what word?"
          context = evolve.option(args, "context") or abort "--context is required — a word is a word somewhere"
          ok = guarded(word, context, evolve, root) do
            evolve.propose(word: word, context: context, **proposal_options(args, evolve))
          end
          puts_proposed(context) if ok
          ok
        end

        # @return [Boolean] whether the gates held
        def set_status(command, args, evolve, root)
          word = args.shift or abort "#{command} what word?"
          context = evolve.option(args, "context") or abort "--context is required"
          guarded(word, context, evolve, root) do
            evolve.set_status(word: word, context: context, to: WORD_STATUS.fetch(command))
          end
        end

        # @return [Boolean] whether the gates held
        def rename(args, evolve, root)
          word = args.shift or abort "rename what word?"
          context = evolve.option(args, "context") or abort "--context is required"
          to = evolve.option(args, "to") or abort "--to is required — a rename goes somewhere"
          ok = guarded(word, context, evolve, root) { evolve.rename(word: word, context: context, to: to) }
          puts_renamed(context, word, to) if ok
          ok
        end

        private

        def proposal_options(args, evolve)
          { body: evolve.option(args, "body", "none"), inner: evolve.option(args, "inner", ""),
            opens: evolve.option(args, "opens", ""), fills: evolve.option(args, "fills", "") }
        end

        def puts_proposed(context)
          puts "Proposed. It reaches no projection until admitted. Before `hecks evolve admit`:"
          puts "  1. teach the #{context} builder the word (and its spec/dsl_spec example)"
        end

        def puts_renamed(context, word, to)
          puts "Renamed. The old spelling keeps parsing — that is the point. Before this holds:"
          puts "  1. alias the new word to the old in the #{context} builder (alias_method :#{to}, :#{word})"
          puts "  2. add the identical-IR example to spec/dsl_spec.rb"
        end
      end
    end
  end
end
