module Hecksagain
  class Bluebook
    class StateTransition
      attr_reader :target, :from

      def initialize(target:, from: nil)
        @target = target.to_s
        @from   = case from
                  when Array then from.map(&:to_s)
                  when nil   then nil
                  else            from.to_s
                  end
      end

      def constrained? = !@from.nil?
    end

    class Lifecycle
      include Hecksagain::IR

      emits_ir(
        field:       -> { field.to_s },
        default:     :default,
        # `expand` is private; a Proc runs in the construct's own
        # context, so declared emission reaches it exactly as the
        # hand-written to_h did.
        transitions: -> { transitions.flat_map { |command, t| expand(command, t) } }
      )

      attr_reader :field, :default, :transitions

      def initialize(field:, default:, transitions: [])
        @field       = field.to_sym
        @default     = default.to_s
        @transitions = transitions
      end

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

        matches.find { |t| applies_from?(t, current_state) } || matches.first
      end

      def applies_from?(transition, current)
        return true unless transition.from

        Array(transition.from).map(&:to_s).include?(current.to_s)
      end
    end
  end
end
