module Hecks
  module Bluebook
    module Behaviour
      # WHAT A LIFECYCLE DOES. Its declared half is a field, a starting
      # state and a transition list. Everything here READS that — which
      # states exist, which transition a command takes, and how one
      # declared transition expands into the several rows the emission
      # carries when `from` names more than one source state.
      module Lifecycle
        def states
          ([default] + transitions.map { |_command, t| t.target }).uniq
        end

        def transitions_for(command)
          transitions.select { |name, _| name == command.to_s }.map { |_, t| t }
        end

        def target_for(command, current_state = nil)
          match_transition(command, current_state)&.target
        end

        private

        # ONE DECLARED TRANSITION IS SEVERAL ROWS when `from` names more
        # than one source state — the emission carries them flat, so the
        # fan-out happens here rather than in whatever reads it.
        def expand(command, transition)
          sources = transition.from.nil? ? [nil] : Array(transition.from)

          sources.map do |source|
            { command: command, to_state: transition.target, from_state: source }
          end
        end

        def match_transition(command, current_state)
          matches = transitions_for(command)
          return nil if matches.empty?
          return matches.first unless current_state

          # NOT `|| matches.first` — that used to silently hand back an
          # ARBITRARY declared transition for `command` whenever none of
          # them actually admitted `current_state`, picking a `target`
          # that command dispatch would in fact have refused (that
          # refusal is `CommandRules::Admissibility#admissible_transition`'s
          # own job, which raises `LifecycleRefused` for exactly this
          # case rather than guessing — this module has no state subject
          # to build that refusal message from, only the two bare
          # values callers passed in). Zero production callers reach
          # this branch today (both real dispatch paths that check a
          # transition go through `admissible_transition`, not
          # `target_for`/`match_transition`), so this raise is a
          # backstop, not a live behaviour change — same shape as
          # `CommandRules::Arithmetic#sign_of`'s own fix.
          matches.find { |t| applies_from?(t, current_state) } ||
            raise(Runtime::WiringError,
                  "no transition for #{command.inspect} admits state #{current_state.inspect} " \
                  "— add a from: covering it, or check admissibility before calling #target_for")
        end

        def applies_from?(transition, current)
          return true unless transition.from

          Array(transition.from).map(&:to_s).include?(current.to_s)
        end
      end
    end
  end
end
