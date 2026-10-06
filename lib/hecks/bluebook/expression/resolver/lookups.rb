# Name and path lookups of the `Resolver` leaf grammar: reading attributes and arguments, and
# walking dotted paths through the values they hold.
module Hecks
  module Bluebook
    module Expression
      # Reopens `Resolver` (see resolver.rb) for lookups.
      module Resolver
        module_function

        def lookup(expr, state, attrs)
          return unwrap_scalar(fetch(expr, state, attrs)) unless expr.include?(".")

          head, *rest = expr.split(".")
          unwrap_scalar(walk_path(fetch(head, state, attrs), rest))
        end

        # Walks dotted segments through a Hash-like value. `key?` picks the symbol or string
        # spelling so a held `false` is not mistaken for an absent key.
        def walk_path(value, segments)
          segments.reduce(value) do |current, segment|
            break nil unless current.respond_to?(:[])

            read_segment(current, segment)
          end
        end

        def read_segment(current, segment)
          if current.is_a?(Hash)
            sym = segment.to_sym
            return current.key?(sym) ? current[sym] : current[segment]
          end

          current[segment]
        rescue TypeError
          # `Array#[]` raises a raw TypeError for a String segment; refuse it instead.
          raise EvaluationError, "cannot read #{segment.inspect} from #{describe(current)}"
        end

        # Unwraps a single-field value object to its scalar so `field == "literal"` works.
        # Gated on the field count, not its name. Mirrors `impl Fielded for Json` in
        # rust/src/kernel/json.rs; change both together.
        def unwrap_scalar(value)
          return value unless wrappable?(value)
          return sole_field_of(value) if value.respond_to?(:value_object)

          hash = value.to_h
          hash.size == 1 && hash.key?(:value) ? hash[:value] : value
        end

        # Whether `value` is a record-like object (neither a Hash nor an Array) that converts
        # to a Hash.
        def wrappable?(value)
          value.respond_to?(:to_h) && !value.is_a?(Hash) && !value.is_a?(Array)
        end

        def sole_field_of(value)
          sole = value.value_object.sole_attribute
          sole ? value[sole.name] : value
        end

        def fetch(name, state, attrs)
          key = name.to_sym
          return attrs[key] if attrs.key?(key)
          return state[key] if known?(state, key)

          raise EvaluationError, "cannot resolve #{name.inspect} — no such attribute or argument"
        end

        def known?(state, key)
          return state.key?(key) if state.respond_to?(:key?)

          !state[key].nil?
        end
      end
    end
  end
end
