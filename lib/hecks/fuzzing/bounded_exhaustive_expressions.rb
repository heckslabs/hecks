require_relative "../bluebook/expression/resolver"
require_relative "../bluebook/expression/evaluator"
require_relative "bounded_exhaustive_expressions/fragments"
require_relative "bounded_exhaustive_expressions/productions"

module Hecks
  module Fuzzing
    # Generates every well-typed expression up to MAX_DEPTH and checks that
    # `Expression::Evaluator` never raises anything but `EvaluationError` on them.
    #
    # Generation is type-directed: a sub-expression is only built where its parent
    # accepts its type, with a small literal palette and a depth bound to stay tractable.
    module BoundedExhaustiveExpressions
      extend Fragments
      extend Productions

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
