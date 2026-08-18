require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class LifecycleBuilder
        GRAMMAR_CONTEXT = "Lifecycle"

        include WordGate

        def initialize(field, default:)
          @field       = field
          @default     = default
          @transitions = []
        end

        # RENAMED FROM `transition` — item #13's full metaprogrammed
        # dispatch (slice 4c). Bootstrap-reachable (syntax.bluebook's
        # own Keyword/Argument entities describe their `status`
        # lifecycle with it), so in BOOTSTRAP_CALLS_FALLBACK.
        def transition_impl(mapping)
          mapping = mapping.dup
          from    = mapping.delete(:from)

          mapping.each do |command, target|
            @transitions << [
              command.to_s,
              StateTransition.new(target: target, from: from)
            ]
          end
        end

        def build
          Lifecycle.new(field: @field, default: @default, transitions: @transitions)
        end

        def self.build(field, default:, &block)
          builder = new(field, default: default)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
