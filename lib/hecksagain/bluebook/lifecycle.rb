require_relative "behaviour/lifecycle"

module Hecksagain
  module Bluebook
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

      def initialize(field:, default:, transitions: [])
        @field       = field.to_sym
        @default     = default.to_s
        @transitions = transitions
      end

    end
  end
end
