# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Edge
        # What the edge checks share for recording a problem: a line of the form
        # `<label> <text>`, and the two shapes of finding that repeat (a value outside a closed set,
        # a key declared more than once). The including class holds `@vocabulary` and `@problems`.
        module Findings
          private

          def member_of(label, field, value, vocabulary)
            return if @vocabulary.fetch(vocabulary).include?(value)

            problem(label, "has #{field} #{value.inspect}; #{field} is one of #{@vocabulary.fetch(vocabulary).join(", ")}")
          end

          def repeated(keys, what)
            keys.tally.each { |key, count| problem(what, "#{yield(key)} is declared #{count} times") if count > 1 }
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
