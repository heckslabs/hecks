# What `Resolver` does with plain values: truthiness, text and list operations, and the
# regular-expression match.
module Hecks
  module Bluebook
    module Expression
      # Reopens `Resolver` (see resolver.rb) for its value operations.
      module Resolver
        module_function

        # Held equal to Vocabulary::SizedType by spec/vocabulary_conformance_spec.
        SIZED_TYPES = Hecks::Vocabulary.fetch("SizedType")

        # Held equal to Vocabulary::ToStringType by spec/vocabulary_conformance_spec.
        TO_STRING_TYPES = Hecks::Vocabulary.fetch("ToStringType")

        # The regex flag letters and the `Regexp` option each sets.
        REGEX_FLAGS = { "i" => Regexp::IGNORECASE, "m" => Regexp::MULTILINE, "x" => Regexp::EXTENDED }.freeze

        def presence_of(node, value)
          present = !blank?(value)
          node.negated ? !present : present
        end

        # Stays `!nil?`; unlike `blank?`, an assigned empty value is set.
        def assignment_of(node, value)
          set = !value.nil?
          node.negated ? !set : set
        end

        def blank?(value)
          return true if value.nil? || value == false

          # Duck-typed: reaching across to Runtime::Value would couple the namespaces. A list
          # is judged by its own emptiness, never coerced: `[0].to_h` would raise TypeError.
          value = value.to_h if wrappable?(value)
          case value
          when String, Array, Hash then value.empty?
          else false
          end
        end

        def matches_regex?(receiver_value, pattern, flags)
          text = scalar_text(receiver_value)
          options = REGEX_FLAGS.sum { |letter, option| flags.include?(letter) ? option : 0 }

          Regexp.new(pattern, options).match?(text)
        rescue RegexpError => e
          # A malformed pattern is an author mistake; refuse it as EvaluationError.
          raise EvaluationError, "match? given an invalid pattern #{pattern.inspect} — #{e.message}"
        end

        def scalar_text(value)
          case value
          when String, Symbol, Integer, Float then value.to_s
          when NilClass then ""
          else
            raise EvaluationError, "match? expects a scalar, got #{value.class}"
          end
        end

        def size_of(value)
          return value.size if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "size expects a list or string, got #{describe(value)}"
        end

        def emptiness_of(value)
          return value.empty? if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "empty? expects a list or string, got #{describe(value)}"
        end

        def split_value(value, separator)
          raise EvaluationError, "split expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.split(separator)
        end

        def last_of(value)
          return value.last if value.respond_to?(:last)

          raise EvaluationError, "last expects a list, got #{describe(value)}"
        end

        def first_of(value)
          return value.first if value.respond_to?(:first)

          raise EvaluationError, "first expects a list, got #{describe(value)}"
        end

        def starts_with?(value, substring)
          raise EvaluationError, "start_with? expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.start_with?(substring)
        end

        def ends_with?(value, substring)
          raise EvaluationError, "end_with? expects a string, got #{describe(value)}" unless value.is_a?(String)

          value.end_with?(substring)
        end

        def string_of(value)
          case value
          when String then value
          when Integer, Float, TrueClass, FalseClass then value.to_s
          when NilClass then ""
          else
            raise EvaluationError, "to_s expects a scalar, got #{describe(value)}"
          end
        end
      end
    end
  end
end
