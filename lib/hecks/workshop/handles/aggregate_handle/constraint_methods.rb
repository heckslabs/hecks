# Hecks::Workshop::AggregateHandle::ConstraintMethods
#
# Validation and invariant handle methods with REPL feedback.
#
module Hecks
  class Workshop
    class AggregateHandle
      module ConstraintMethods
        def validation(field, rules)
          @builder.validation(field, rules)
          puts "#{field} validation added to #{@name} (#{rules.keys.join(', ')})"
          self
        end

        def invariant(message, &block)
          @builder.invariant(message, &block)
          puts "invariant added to #{@name}: #{message}"
          self
        end
      end
    end
  end
end
