module Hecks
  module Bluebook
    module TranslationExpression
      # Computes a parsed expression for one record's state. The reference semantics the
      # compiled Postgres form is held to.
      module Evaluator
        module_function

        # @param tree [Array] a tree `TranslationExpression.parse` returned
        # @param state [Hash] the record's stored state
        # @return [String, nil] the computed text; nil when the expression has no value
        def call(tree, state)
          case tree.first
          when "lit" then tree[1]
          when "null" then nil
          when "ref" then reference(tree[1], state)
          else apply(tree.first, tree.drop(1), state)
          end
        end

        # Reads a dotted path out of a record; only text counts as a value.
        def reference(path, state)
          value = path.split(".").inject(state) { |held, key| held.is_a?(Hash) ? member(held, key) : nil }
          value.is_a?(String) ? value : nil
        end

        # A record's top-level keys are symbols, a value object's are strings.
        def member(hash, key) = hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key]

        def apply(name, arguments, state)
          return lookup(arguments, state) if name == "lookup"
          return replace(arguments, state) if name == "replace"

          values = arguments.map { |argument| call(argument, state) }
          return nil if values.any?(&:nil?)

          fold(name, values)
        end

        def fold(name, values)
          case name
          when "lower" then values.first.downcase(:ascii)
          when "upper" then values.first.upcase(:ascii)
          else values.join
          end
        end

        def replace(arguments, state)
          target, from, to = arguments
          call(target, state)&.gsub(from.last) { to.last }
        end

        def lookup(arguments, state)
          key, table, fallback = arguments
          value = call(key, state)
          return nil if value.nil?

          table.fetch(value) { call(fallback, state) }
        end
      end
    end
  end
end
