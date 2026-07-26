# Lifecycle — a state machine on one aggregate field.
#
# The field holds the state, the default is where a new instance starts, and each
# transition maps a COMMAND to the state it moves to. A transition may name the
# state(s) it moves FROM, and a command declared several times with different
# `from:` walks a progression — which is why transitions are an ordered ARRAY of
# pairs rather than a Hash keyed by command.
#
#   lifecycle :status, default: "pending" do
#     transition "Purchase" => "sold"
#     transition "Refund"   => "pending", from: "sold"
#     transition "Archive"  => "archived", from: ["sold", "pending"]
#   end
#
# `from:` KEEPS ITS SHAPE HERE. A list stays a list. The interpreter wants one
# record per (command, to, from) triple, but flattening is a rendering concern
# and it belongs to the exporter — the same place Hecks does it (canonical_ir.rb
# `transitions_to_array`). Doing it in the builder would let the projection
# dictate how a bluebook is written, and the arrow only runs the other way.
module Hecksagain
  module Bluebook
    module IR
      # One transition's destination and its optional source constraint.
      # `from` is nil (any state), a String, or an Array of Strings.
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
        attr_reader :field, :default, :transitions

        def initialize(field:, default:, transitions: [])
          @field       = field.to_sym
          @default     = default.to_s
          @transitions = transitions
        end

        # Every state this machine can be in, the default included.
        def states
          ([default] + transitions.map { |_command, t| t.target }).uniq
        end

        # All transitions declared for one command — possibly several, each with
        # its own `from:`.
        def transitions_for(command)
          transitions.select { |name, _| name == command.to_s }.map { |_, t| t }
        end

        # The state a command moves to. With several candidates, `current_state`
        # picks the one whose `from:` admits it ; without it, first declared wins.
        def target_for(command, current_state = nil)
          match_transition(command, current_state)&.target
        end

        # The canonical dump. THIS is where `from: [a, b]` becomes one record
        # per source state — the interpreter wants a flat (command, to, from)
        # triple, and rendering is the right place to give it one. The authoring
        # shape above is untouched, so how a bluebook is written never bends to
        # what a projection finds convenient to read.
        def to_h
          {
            field:       field.to_s,
            default:     default,
            transitions: transitions.flat_map { |command, t| expand(command, t) }
          }
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
end
