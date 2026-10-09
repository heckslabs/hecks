require_relative "behaviour/lifecycle"

module Hecks
  module Bluebook
    # One declared `transition` row: the target state, and optionally the `from:` state(s) it needs.
    # An unguarded transition (`from: nil`) applies from any state.
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

      def constrained? = !@from.nil?
    end

    # The built form of a `lifecycle :field, default: ... do ... end` block.
    # Reads (`states`, `target_for`, ...) come from `Behaviour::Lifecycle`.
    class Lifecycle
      include Hecks::IR
      include Behaviour::Lifecycle

      emits_ir(
        field:       -> { field.to_s },
        default:     :default,
        # `expand` is private; a Proc runs in the construct's own context, so it can reach it.
        transitions: -> { transitions.flat_map { |command, t| expand(command, t) } },
        # Dropped from `to_h` when empty (see below), so an unmarked lifecycle's IR is unchanged.
        marks:       :marks
      )

      attr_reader :field, :default, :transitions, :marks

      # @param field [Symbol, String] the attribute this state machine lives on
      # @param default [String, Symbol] the state a new record starts in
      # @param transitions [Array<Array(String, Bluebook::StateTransition)>] each declared
      #   `command name, StateTransition` pair, in declaration order
      # @param marks [Hash{String, Symbol => Array<String, Symbol>}] each named meaning and the
      #   states that carry it, such as `holds_seat => ["pending", "succeeded"]`
      def initialize(field:, default:, transitions: [], marks: {})
        @field       = field.to_sym
        @default     = default.to_s
        @transitions = transitions
        @marks       = marks.to_h { |name, states| [name.to_s, Array(states).map(&:to_s)] }
      end

      # The states a named meaning marks.
      #
      # @param name [String, Symbol] the mark, such as `:holds_seat`
      # @return [Array<String>, nil] the states in declared order, or nil when no such mark
      def marked(name) = marks[name.to_s]

      # `marks` is left out when the lifecycle declares none, so IR written before the word
      # existed stays byte-identical.
      def to_h
        row = super
        row.delete(:marks) if marks.empty?
        row
      end
    end
  end
end
