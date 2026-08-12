module Hecksagain
  module Bluebook
    module DSL
      class LifecycleBuilder
        def initialize(field, default:)
          @field       = field
          @default     = default
          @transitions = []
        end

        def transition(mapping)
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
