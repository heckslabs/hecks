require_relative "../plain_english"

module Hecks
  module Projections
    module Statements
      # The statements a holder's lifecycle and commands carry: where it starts, what moves it
      # between states, who does each command, and every rule a command checks before and after.
      # Rule text is the author's own; only the command's name is turned into words around it.
      #
      #   Actions.rules(order) # => ["Adding a topping requires: at most 10 toppings.", ...]
      module Actions
        module_function

        # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct with a lifecycle
        # @return [Array<String>] where it starts, then one sentence per move
        def lifecycle(holder)
          lifecycle = holder.respond_to?(:lifecycle) && holder.lifecycle
          return [] unless lifecycle

          start = "#{PlainEnglish.upper(PlainEnglish.a(PlainEnglish.noun(holder.hecks_name)))} " \
                  "starts out #{PlainEnglish.state(lifecycle.default)}."
          [start, *moves(lifecycle).map { |command, move| move_sentence(holder, command, move) }]
        end

        # Each command's moves, as `[command, { from: [...], to: state }]`, merged across the
        # transitions a command declares from more than one state.
        def moves(lifecycle)
          merged = lifecycle.transitions.each_with_object({}) do |(command, transition), found|
            key = [command.to_s, transition.target]
            found[key] ||= { from: [], to: transition.target }
            found[key][:from] |= Array(transition.from)
          end
          merged.map { |(command, _target), move| [command, move] }
        end

        # "Purchasing an order moves it from available to sold."
        def move_sentence(holder, command, move)
          doing = PlainEnglish.doing(command, holder.hecks_name)
          noun = PlainEnglish.noun(holder.hecks_name)
          object = doing.match?(/\b#{Regexp.escape(noun)}\b/) ? "it" : "the #{noun}"
          "#{PlainEnglish.upper(doing)} #{move_phrase(move, object)}."
        end

        # "moves it from available to sold", "keeps it failed", or "moves it to closed".
        #
        # @param move [Hash] `{ from: [...], to: state }`, as `moves` answers it
        # @param object [String] what is moved, such as "it" or "the order"
        # @return [String] the verb phrase
        def move_phrase(move, object)
          to = PlainEnglish.state(move[:to])
          return "keeps #{object} #{to}" if move[:from] == [move[:to]]
          return "moves #{object} to #{to}" if move[:from].empty?

          "moves #{object} from #{PlainEnglish.states(move[:from])} to #{to}"
        end

        # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct the commands are on
        # @return [Array<String>] each command's role, its rules, and what it guarantees after
        def rules(holder)
          holder.commands.flat_map { |command| command_rules(holder, command) }
        end

        def command_rules(holder, command)
          doing = PlainEnglish.doing(command.hecks_name, holder.hecks_name)
          role = command.role && "#{PlainEnglish.upper(doing)} is done by the #{PlainEnglish.noun(command.role)}."
          [role, *checks(holder, command).map { |rule| "#{PlainEnglish.upper(doing)} requires: #{rule}." },
           *command.ensures.map { |rule| "After #{doing}: #{text(rule)}." }].compact
        end

        # What a command checks first: the state it starts from, then each `given` in the
        # author's words. The state is left out when a move sentence already says it.
        #
        # @param said_by_move [Boolean] whether a move sentence states the starting state
        # @return [Array<String>] the rules, without a closing period
        def checks(holder, command, said_by_move: true)
          [state_check(holder, command, said_by_move), *command.givens.map { |rule| text(rule) }].compact
        end

        # "the order is available", for a command declared `from:` a state.
        def state_check(holder, command, said_by_move)
          return nil unless command.from
          return nil if said_by_move && moved_by?(holder, command)

          "the #{PlainEnglish.noun(holder.hecks_name)} is #{PlainEnglish.states(Array(command.from))}"
        end

        def moved_by?(holder, command)
          lifecycle = holder.respond_to?(:lifecycle) && holder.lifecycle
          return false unless lifecycle

          lifecycle.transitions.any? { |name, _transition| name.to_s == command.hecks_name }
        end

        # A rule's description as written, without a trailing period.
        def text(rule)
          description = rule.description
          description.to_s.strip.delete_suffix(".")
        end
      end
    end
  end
end
