module Hecks
  module Fuzzing
    module BoundedExhaustiveExpressions
      # The recursive production rules, one per result type; mixed into
      # `BoundedExhaustiveExpressions`, whose `leaves`, `bounded`, `sample`, `pairs` and `cross`
      # they build on.
      #
      # The order each rule calls `bounded` and `with_element_leaf` in is part of its behavior:
      # `with_element_leaf` invalidates only its own element type's cache entries, so a list
      # built while a block parameter is bound is cached for the types it touches.
      module Productions
        # Numeric from Addition, Modulo, Size (string or array), and First/Last of a numeric array.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] numeric expressions one construct deep
        def numeric_productions(depth)
          sub = bounded(:numeric, depth - 1)
          # Modulo's receiver is restricted to `resolver_numeric_leaves`: `Resolver.parse` splits
          # on `+` before the `.modulo` suffix, so "0 + 0.modulo(1)" parses as `0 + (0.modulo(1))`.
          pairs(sub).map { |a, b| "#{a} + #{b}" } +
            cross(resolver_numeric_leaves(depth - 1), sub).map { |a, b| "#{a}.modulo(#{b})" } +
            sized_numerics(depth - 1)
        end

        # Numeric from Size of a string or an array, and First/Last of a numeric array.
        #
        # @param depth [Integer] maximum recursive steps remaining for the receivers
        # @return [Array<String>] the `.size`, `.first` and `.last` expressions
        def sized_numerics(depth)
          bounded(:string, depth).map { |s| "#{s}.size" } +
            bounded(:array, depth).map { |a| "#{a}.size" } +
            first_and_last(sample(numeric_array_productions(depth)))
        end

        # Booleans safe as the receiver of a Resolver-level suffix such as `.to_s` (a boolean-
        # typed expression, is wanted). Found live, the same way the
        # nested `.modulo` bug was: `Compare`, `Include`, `Or`, `And` and `Not` are boolean-
        # typed at `interpret` time, but `Evaluator`-level syntax, not
        # something `Resolver.parse` can take as a receiver, even parenthesized.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] boolean expressions parsed by a Resolver suffix rule
        def resolver_boolean_leaves(depth)
          leaves(:boolean) +
            sign_tests(resolver_numeric_leaves(depth)) +
            bounded(:string, depth).flat_map { |s| string_suffix_tests(s) } +
            empty_tests(array_operands(depth)) +
            sample(block_predicate_productions(depth))
        end

        # Numerics safe to embed as the receiver of a Resolver-level suffix such as `.to_s`.
        #
        # A bare `Addition` is excluded: `Resolver.parse` splits on `+` before matching the
        # suffix, so "0 + 0.to_s" parses as `0 + (0.to_s)`, not `(0 + 0).to_s`.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] numeric expressions that are never a bare top-level `Addition`
        def resolver_numeric_leaves(depth)
          return leaves(:numeric) if depth <= 0

          # Self-referential so Modulo's receiver stays restricted; its argument is unrestricted.
          leaves(:numeric) +
            cross(resolver_numeric_leaves(depth - 1), bounded(:numeric, depth - 1)).map { |a, b| "#{a}.modulo(#{b})" } +
            sized_numerics(depth)
        end

        # String from ToS of numeric, boolean, nil or string, and First/Last of a string array.
        #
        # `Split` is not listed: it produces an array, never a String.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] string expressions one construct deep
        def string_productions(depth)
          inner = depth - 1
          [sample(resolver_numeric_leaves(inner)), sample(resolver_boolean_leaves(inner)),
           bounded(:nil_type, inner), bounded(:string, inner)].flat_map { |list| list.map { |x| "#{x}.to_s" } } +
            first_and_last(sample(string_array_productions(inner)))
        end

        # Array from Split and same-type array literals; array is mostly a receiver type, so
        # few producers are needed.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] array expressions one construct deep; `[]` at depth 0
        def array_productions(depth)
          return [] if depth <= 0

          bounded(:string, depth - 1).map { |s| "#{s}.split(\",\")" } +
            [numeric_array_literal(depth - 1), string_array_literal(depth - 1)]
        end

        # Builds a two-element numeric array literal at `depth`.
        #
        # @param depth [Integer] maximum recursive steps remaining for its elements
        # @return [String] the literal's source text
        def numeric_array_literal(depth) = "[#{bounded(:numeric, depth).first(2).join(", ")}]"

        # Builds a two-element string array literal at `depth`.
        #
        # @param depth [Integer] maximum recursive steps remaining for its elements
        # @return [String] the literal's source text
        def string_array_literal(depth) = "[#{bounded(:string, depth).first(2).join(", ")}]"

        # Arrays known by construction to hold numeric elements, so `.first`/`.last` and block
        # predicates know the element type without a richer AST.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] `"arr_num"` plus a numeric array literal at `depth`
        def numeric_array_productions(depth)
          ["arr_num", numeric_array_literal(depth)]
          # no Split entry: a Split of a string never yields numeric elements
        end

        # Arrays known by construction to hold string elements; the twin of
        # `numeric_array_productions`.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] `"arr_str"`, a string array literal, and every string `Split`
        def string_array_productions(depth)
          ["arr_str", string_array_literal(depth)] + bounded(:string, depth).map { |s| "#{s}.split(\",\")" }
        end

        # Boolean from every comparison and predicate construct; a `given` body is boolean-
        # typed at its own top level (`Evaluator.truthy?`), so this is also
        # the set `all_predicates` draws from.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] boolean expressions one construct deep
        def boolean_productions(depth)
          inner = depth - 1
          sub = bounded(:boolean, inner)
          num = bounded(:numeric, inner)
          str = bounded(:string, inner)

          comparisons(num, str) + operand_tests(str, inner) + string_tests(str) + connectives(sub) +
            block_predicate_productions(inner) + include_productions(inner)
        end

        # The sign and emptiness predicates over numeric, string and array operands.
        #
        # @param str [Array<String>] string operands
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] the predicate expressions
        def operand_tests(str, depth)
          # `resolver_numeric_leaves`, not `num`: a suffix match is a plain trailing strip, so
          # an `Addition` would mis-split ("0 + 0.positive?" parses as `0 + (0.positive?)`).
          sign_tests(resolver_numeric_leaves(depth)) + empty_tests(str + array_operands(depth))
        end

        # Every array source a predicate may be asked `.empty?`: numeric, string, and plain.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] the sampled array expressions
        def array_operands(depth)
          sample(numeric_array_productions(depth)) + sample(string_array_productions(depth)) + bounded(:array, depth)
        end

        # `.all?`/`.any?`/`.none?` over each known-element-typed array, with a predicate body
        # bound to `BLOCK_PARAM`.
        #
        # The only construct where Resolver and Evaluator recurse into each other, and the
        # only one that can nest into another block predicate.
        #
        # @param depth [Integer] maximum recursive steps remaining for the predicate body
        # @return [Array<String>] `.all?`/`.any?`/`.none?` calls over each
        #   known-element-typed array source, one per predicate body `predicate_bodies`
        #   produces; `[]` if `depth` is negative
        def block_predicate_productions(depth)
          return [] if depth.negative?

          typed_array_sources(depth).flat_map do |array_text, element_type|
            predicate_bodies(element_type, depth).flat_map do |body|
              %w[all? any? none?].map { |mode| "#{array_text}.#{mode} { |#{BLOCK_PARAM}| #{body} }" }
            end
          end
        end

        # The array sources a block predicate ranges over, paired with their element type.
        #
        # @param depth [Integer] maximum recursive steps remaining for the literals
        # @return [Array<Array(String, Symbol)>] source text and element type
        def typed_array_sources(depth)
          [
            ["arr_num", :numeric], [numeric_array_literal(depth), :numeric],
            ["arr_str", :string], [string_array_literal(depth), :string]
          ]
        end

        # The predicate body a block gets: `boolean_productions` with `BLOCK_PARAM` also a leaf.
        # Sampled because each body is multiplied by three modes and four array sources.
        #
        # @param element_type [Symbol] the type `BLOCK_PARAM` is bound to inside the block
        # @param depth [Integer] maximum recursive steps remaining for the body
        # @return [Array<String>] a sampled set of boolean expressions
        def predicate_bodies(element_type, depth)
          sample(with_element_leaf(element_type) { boolean_productions(depth) })
        end

        # `haystack.include?(needle)`: a String haystack needs a String needle, an Array
        # haystack admits any needle type.
        #
        # @param depth [Integer] maximum recursive steps remaining
        # @return [Array<String>] `include?` expressions for string and array haystacks
        def include_productions(depth)
          str = bounded(:string, depth)
          pairs(str).map { |haystack, needle| "#{haystack}.include?(#{needle})" } +
            sample(numeric_array_productions(depth)).product(bounded(:numeric, depth)).map do |arr, needle|
              "#{arr}.include?(#{needle})"
            end +
            sample(string_array_productions(depth)).product(bounded(:string, depth)).map do |arr, needle|
              "#{arr}.include?(#{needle})"
            end
        end
      end
    end
  end
end
