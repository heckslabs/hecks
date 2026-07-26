# LifecycleBuilder — evaluates a `lifecycle :status, default: "x" do ... end`
# block.
#
# Brought over from Hecks's DSL::LifecycleBuilder. The DSL surface is unchanged,
# down to the `from:` kwarg riding inside the same hash as the command mapping —
# a bluebook written for Hecks reads here without an edit, which is the whole
# point of bringing it rather than writing it.
#
#   lifecycle :status, default: "pending" do
#     transition "Purchase" => "sold"
#     transition "Refund"   => "pending", from: "sold"
#     transition "Archive"  => "archived", from: ["sold", "pending"]
#   end
#
# Transitions are an ordered ARRAY of [command, StateTransition] pairs, not a
# Hash — one command may be declared several times with different `from:` to
# walk a progression, and a Hash would keep only the last.
module Hecksagain
  module Bluebook
    module DSL
      class LifecycleBuilder
        def initialize(field, default:)
          @field       = field
          @default     = default
          @transitions = []
        end

        # Map a command to the state it moves to, optionally constrained by the
        # state(s) it may move from.
        #
        # `from:` arrives in the same hash as the mapping, so it is lifted out
        # before the rest is read as command => state pairs. It is stored as
        # WRITTEN — a list stays a list. Expanding it into one record per source
        # state is the exporter's job, not the author's.
        def transition(mapping)
          mapping = mapping.dup
          from    = mapping.delete(:from)

          mapping.each do |command, target|
            @transitions << [
              command.to_s,
              IR::StateTransition.new(target: target, from: from)
            ]
          end
        end

        def build
          IR::Lifecycle.new(field: @field, default: @default, transitions: @transitions)
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
