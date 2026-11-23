module Hecks
  module Bluebook
    module DSL
      class CommandBuilder
        # A step (`increment:` or `decrement:`) written beside `clamp:` is one mutation: the clamp
        # is held apart as the step's bounds.
        module StepBounds
          private

          # Separates a `clamp:` pair from the step it bounds; any other pairing is left whole.
          def split_step_bounds(target, named)
            steps = named.keys & %i[increment decrement]
            return [named, nil] unless named.key?(:clamp) && steps.size == 1 && named.size == 2

            [named.except(:clamp), checked_bounds(target, named[:clamp])]
          end

          def checked_bounds(target, bounds)
            valid = bounds.is_a?(::Array) && bounds.size == 2 && bounds.all?(::Numeric) && bounds[0] <= bounds[1]
            return bounds if valid

            raise Malformed,
                  "#{@name}'s sets :#{target} clamp: #{bounds.inspect} is not a [min, max] pair of numbers in order"
          end
        end
      end
    end
  end
end
