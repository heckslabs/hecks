require_relative "behaviour/lifecycle"

module Hecks
  module Bluebook
    # One declared `transition` row — the state a command moves an
    # aggregate or entity to, and, when guarded, the state(s) it must
    # currently be in (`from:`) for the transition to apply. An unguarded
    # transition (`from: nil`) applies from any current state.
    class StateTransition
      attr_reader :target, :from

      # @param target [String, Symbol] the state this transition moves the record to
      # @param from [String, Symbol, Array<String, Symbol>, nil] the state, or states, this
      #   transition applies from; `nil` means any current state admits it
      def initialize(target:, from: nil)
        @target = target.to_s
        @from   = case from
                  when Array then from.map(&:to_s)
                  when nil   then nil
                  else            from.to_s
                  end
      end

      # Says whether this transition is guarded to specific source states.
      #
      # @return [Boolean] whether this transition is guarded to specific source states,
      #   rather than applying from any current state
      def constrained? = !@from.nil?
    end

    # The built form of a `lifecycle :field, default: ... do ... end`
    # block, produced by `DSL::LifecycleBuilder` — the field a state
    # machine lives on, its starting value, and the declared transition
    # table. `Behaviour::Lifecycle` supplies the reads (`states`,
    # `target_for`, ...) built purely from this data.
    class Lifecycle
      include Hecks::IR
      include Behaviour::Lifecycle

      emits_ir(
        field:       -> { field.to_s },
        default:     :default,
        # `expand` is private; a Proc runs in the construct's own
        # context, so declared emission reaches it exactly as the
        # hand-written to_h did.
        transitions: -> { transitions.flat_map { |command, t| expand(command, t) } }
      )

      attr_reader :field, :default, :transitions

      # @param field [Symbol, String] the attribute this state machine lives on
      # @param default [String, Symbol] the state a new record starts in
      # @param transitions [Array<Array(String, Bluebook::StateTransition)>] each declared
      #   `command name, StateTransition` pair, in declaration order
      def initialize(field:, default:, transitions: [])
        @field       = field.to_sym
        @default     = default.to_s
        @transitions = transitions
      end
    end
  end
end
