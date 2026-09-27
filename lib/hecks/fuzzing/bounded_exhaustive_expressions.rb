require_relative "../bluebook/expression/resolver"
require_relative "../bluebook/expression/evaluator"

module Hecks
  module Fuzzing
    # Generates every well-typed expression up to MAX_DEPTH and checks that
    # `Expression::Evaluator` never raises anything but `EvaluationError` on them.
    #
    # Generation is type-directed: a sub-expression is only built where its parent
    # accepts its type, with a small literal palette and a depth bound to stay tractable.
    module BoundedExhaustiveExpressions
      module_function

      # Integer and Float are one type: the resolver never distinguishes them.
      TYPES = %i[numeric string boolean array nil_type].freeze

      # A small literal palette; boundary values (Bignum, NaN, unicode) are covered elsewhere.
      TYPE_LEAVES = {
        numeric:  ["0", "1", "-1"].freeze,
        string:   ['""', '"a"'].freeze,
        boolean:  %w[true false].freeze,
        nil_type: %w[nil].freeze
      }.freeze

      # Names must not collide with BLOCK_PARAM: a block parameter shadows a same-named attribute.
      SYNTHETIC_ATTRS = {
        numeric: %w[num_a num_b].freeze,
        string:  %w[str_a str_b].freeze,
        boolean: %w[bool_a bool_b].freeze,
        array:   %w[arr_num arr_str].freeze
      }.freeze

      # Element type per array attribute, so a block parameter gets the right leaf set.
      ARRAY_ELEMENT_TYPE = { "arr_num" => :numeric, "arr_str" => :string }.freeze

      BLOCK_PARAM = "el".freeze

      MAX_DEPTH = 3

      # Half the attributes are bare scalars, half wrapped in `SingleFieldVO`, so the
      # value-object unwrap path in `Resolver#unwrap_scalar` is exercised.
      #
      # Not a plain Hash: `unwrap_scalar` leaves a Hash wrapped, so a `{value: X}` Hash
      # would fail every scalar-typed operation.
      SingleFieldVO = Struct.new(:value) do
        def to_h = { value: value }
      end

      # Builds the fixed state every generated predicate is interpreted against.
      #
      # @return [Hash{Symbol => Object}] symbol-keyed synthetic state
      def synthetic_state
        {
          num_a:   3,
          num_b:   SingleFieldVO.new(5),
          str_a:   "hello",
          str_b:   SingleFieldVO.new("world"),
          bool_a:  true,
          bool_b:  SingleFieldVO.new(false),
          arr_num: [1, SingleFieldVO.new(2), 3],
          arr_str: ["x", SingleFieldVO.new("y"), "z"]
        }
      end

      # The `attrs` half of the interpret call; every name lives in `synthetic_state`.
      #
      # @return [Hash] always `{}`
      def synthetic_attrs = {}

      # Lists every terminal expression of `type`: literals, synthetic attribute names,
      # and any bound block-parameter leaf.
      #
      # @param type [Symbol] one of `TYPES`
      # @return [Array<String>] the terminal expressions for `type`
      def leaves(type)
        (TYPE_LEAVES[type] || []) + (SYNTHETIC_ATTRS[type] || []) + Array(bound_leaves[type])
      end

      # The per-type stack of bound block-parameter leaf names.
      #
      # A stack because nested block predicates push a second `BLOCK_PARAM`; the inner one
      # shadows the outer, which the interpreter handles by rebinding per level.
      #
      # @return [Hash{Symbol => Array<String>}] each type's stack, usually `[]` or `["el"]`
      def bound_leaves = @bound_leaves ||= Hash.new { |h, k| h[k] = [] }

      # Runs the block with `BLOCK_PARAM` admitted as a leaf of `element_type`.
      #
      # @param element_type [Symbol] the type `BLOCK_PARAM` is bound to
      # @yield runs with the leaf pushed and affected cache entries invalidated
      # @return [Object] the block's result
      def with_element_leaf(element_type)
        bound_leaves[element_type] << BLOCK_PARAM
        cache.delete_if { |(type, _depth), _| type == element_type }
        yield
      ensure
        bound_leaves[element_type].pop
        cache.delete_if { |(type, _depth), _| type == element_type }
      end

      # Lists every expression of `type` reachable in at most `depth` steps, memoized
      # so cost grows additively per level rather than multiplicatively.
      #
      # @param type [Symbol] one of `TYPES`
      # @param depth [Integer] maximum recursive steps remaining
      # @return [Array<String>] the deduplicated expressions; `leaves(type)` at depth 0
      def productions(type, depth)
        cache[[type, depth]] ||= begin
          base = leaves(type)
          depth <= 0 ? base : (base + recursive_productions(type, depth)).uniq
        end
      end

      # The `productions` memo, keyed by `[type, depth]`.
      #
      # @return [Hash{Array(Symbol, Integer) => Array<String>}] the cache
      def cache = @cache ||= {}

      # Dispatches to the recursive production rule for `type`.
      #
      # @param type [Symbol] one of `TYPES`
      # @param depth [Integer] maximum recursive steps remaining
      # @return [Array<String>] the non-leaf expressions; `[]` for `:nil_type`
      # @raise [ArgumentError] if `type` is outside `TYPES`
      def recursive_productions(type, depth)
        case type
        when :numeric  then numeric_productions(depth)
        when :string   then string_productions(depth)
        when :boolean  then boolean_productions(depth)
        when :array    then array_productions(depth)
        # nothing produces nil as source text; Find's "not found" is a runtime outcome
        when :nil_type then []
        else raise ArgumentError, "no production rule for type #{type.inspect}"
        end
      end

      # Samples `productions(type, depth)` down to `SAMPLE_CAP` entries.
      #
      # Every internal sub-expression list goes through this: bounding the inputs (not the
      # final output) is what keeps growth near-linear in depth instead of combinatorial.
      #
      # @param type [Symbol] one of `TYPES`
      # @param depth [Integer] maximum recursive steps remaining
      # @return [Array<String>] at most `SAMPLE_CAP` expressions
      def bounded(type, depth) = sample(productions(type, depth))

      # NUMERIC from Addition, Modulo, Size (string or array), and First/Last of a numeric array.
      #
      # @param depth [Integer] maximum recursive steps remaining
      # @return [Array<String>] numeric expressions one construct deep
      def numeric_productions(depth)
        sub = bounded(:numeric, depth - 1)
        # Modulo's receiver is restricted to `resolver_numeric_leaves`: `Resolver.parse` splits
        # on `+` before the `.modulo` suffix, so "0 + 0.modulo(1)" parses as `0 + (0.modulo(1))`.
        pairs(sub).map { |a, b| "#{a} + #{b}" } +
          cross(resolver_numeric_leaves(depth - 1), sub).map { |a, b| "#{a}.modulo(#{b})" } +
          bounded(:string, depth - 1).map { |s| "#{s}.size" } +
          bounded(:array, depth - 1).map { |a| "#{a}.size" } +
          sample(numeric_array_productions(depth - 1)).flat_map { |a| ["#{a}.first", "#{a}.last"] }
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
          resolver_numeric_leaves(depth).flat_map { |n| ["#{n}.positive?", "#{n}.negative?", "#{n}.zero?"] } +
          bounded(:string, depth).flat_map do |s|
            ["#{s}.present?", "#{s}.blank?", "#{s}.match?(/a/)", "#{s}.start_with?(\"a\")", "#{s}.end_with?(\"a\")"]
          end +
          (sample(numeric_array_productions(depth)) + sample(string_array_productions(depth)) + bounded(:array, depth)).map do |x|
            "#{x}.empty?"
          end +
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
          bounded(:string, depth).map { |s| "#{s}.size" } +
          bounded(:array, depth).map { |a| "#{a}.size" } +
          sample(numeric_array_productions(depth)).flat_map { |a| ["#{a}.first", "#{a}.last"] }
      end

      # STRING from ToS of numeric, boolean, nil or string, and First/Last of a string array.
      #
      # `Split` is not listed: it produces an array, never a String.
      #
      # @param depth [Integer] maximum recursive steps remaining
      # @return [Array<String>] string expressions one construct deep
      def string_productions(depth)
        sample(resolver_numeric_leaves(depth - 1)).map { |n| "#{n}.to_s" } +
          sample(resolver_boolean_leaves(depth - 1)).map { |b| "#{b}.to_s" } +
          bounded(:nil_type, depth - 1).map { |n| "#{n}.to_s" } +
          bounded(:string, depth - 1).map { |s| "#{s}.to_s" } +
          sample(string_array_productions(depth - 1)).flat_map { |a| ["#{a}.first", "#{a}.last"] }
      end

      # ARRAY from Split and same-type array literals; array is mostly a receiver type, so
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
      def numeric_array_literal(depth) = "[#{bounded(:numeric, depth).first(2).join(', ')}]"

      # Builds a two-element string array literal at `depth`.
      #
      # @param depth [Integer] maximum recursive steps remaining for its elements
      # @return [String] the literal's source text
      def string_array_literal(depth)  = "[#{bounded(:string, depth).first(2).join(', ')}]"

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

      # BOOLEAN from every comparison and predicate construct; a `given` body is boolean-
      # typed at its own top level (`Evaluator.truthy?`), so this is also
      # the set `all_predicates` draws from.
      #
      # One table rather than helper methods: each term's rationale sits beside it.
      # rubocop:disable-next Metrics/AbcSize
      #
      # @param depth [Integer] maximum recursive steps remaining
      # @return [Array<String>] boolean expressions one construct deep
      def boolean_productions(depth)
        sub = bounded(:boolean, depth - 1)
        num = bounded(:numeric, depth - 1)
        str = bounded(:string, depth - 1)

        pairs(num).map { |a, b| "#{a} == #{b}" } +
          pairs(num).map { |a, b| "#{a} > #{b}" } +
          pairs(str).map { |a, b| "#{a} == #{b}" } +
          pairs(str).map { |a, b| "#{a} < #{b}" } +
          # `resolver_numeric_leaves`, not `num`: a suffix match is a plain trailing strip, so
          # an `Addition` would mis-split ("0 + 0.positive?" parses as `0 + (0.positive?)`).
          resolver_numeric_leaves(depth - 1).flat_map { |n| ["#{n}.positive?", "#{n}.negative?", "#{n}.zero?"] } +
          (str + sample(numeric_array_productions(depth - 1)) + sample(string_array_productions(depth - 1)) + bounded(:array,
                                                                                                                      depth - 1))
          .map do |x|
            "#{x}.empty?"
          end +
          str.map { |s| "#{s}.match?(/a/)" } +
          str.flat_map { |s| ["#{s}.present?", "#{s}.blank?"] } +
          str.flat_map { |s| ["#{s}.start_with?(\"a\")", "#{s}.end_with?(\"a\")"] } +
          pairs(sub).flat_map { |a, b| ["#{a} && #{b}", "#{a} || #{b}"] } +
          sub.map { |b| "!#{b}" } +
          block_predicate_productions(depth - 1) +
          include_productions(depth - 1)
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

        [
          ["arr_num", :numeric], [numeric_array_literal(depth), :numeric],
          ["arr_str", :string], [string_array_literal(depth), :string]
        ].flat_map do |array_text, element_type|
          predicate_bodies(element_type, depth).flat_map do |body|
            %w[all? any? none?].map { |mode| "#{array_text}.#{mode} { |#{BLOCK_PARAM}| #{body} }" }
          end
        end
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

      # Cap on any sampled list. A full cross product explodes to tens of millions of cases,
      # and `Or`/`And`/`Not` do no type-dependent work, so sampled operands cover them.
      SAMPLE_CAP = 14

      # Evenly samples `list` down to at most `SAMPLE_CAP` entries.
      #
      # @param list [Array<String>] the list to sample
      # @return [Array<String>] `list` if short enough, else every n-th entry, evenly spaced
      def sample(list) = list.size <= SAMPLE_CAP ? list : list.each_slice(list.size.fdiv(SAMPLE_CAP).ceil).map(&:first)

      # Builds every pair of one sampled list with itself.
      #
      # @param list [Array<String>] the list to sample and pair
      # @return [Array<Array(String, String)>] the sampled list's self cross product
      def pairs(list)
        sampled = sample(list)
        sampled.product(sampled)
      end

      # The two-list twin of `pairs`, for constructs whose sides need different operand sets.
      #
      # @param left [Array<String>] the left-hand list to sample
      # @param right [Array<String>] the right-hand list to sample
      # @return [Array<Array(String, String)>] the cross product of the sampled lists
      def cross(left, right) = sample(left).product(sample(right))

      # Every boolean-typed expression up to `max_depth`, deduplicated.
      #
      # @param max_depth [Integer] maximum recursive depth to generate up to
      # @return [Array<String>] the deduplicated expressions
      def all_predicates(max_depth = MAX_DEPTH)
        productions(:boolean, max_depth).uniq
      end

      # Interprets one predicate against the synthetic state.
      #
      # A true/false answer or a clean `EvaluationError` is the sublanguage working; only
      # any other escaping error is a finding.
      #
      # @param expr [String] a generated or hand-written expression source
      # @return [Hash{Symbol => Object}] `{ok: true, result:}`, `{ok: true, result: :refused,
      #   message:}` for `EvaluationError`, or `{ok: false, error:}` for anything else
      def check(expr)
        result = Hecks::Bluebook::Expression::Evaluator.call(expr, synthetic_state, synthetic_attrs)
        { ok: true, result: result }
      rescue Hecks::Bluebook::Expression::EvaluationError => e
        { ok: true, result: :refused, message: e.message }
      rescue StandardError => e
        { ok: false, error: e }
      end
    end
  end
end
