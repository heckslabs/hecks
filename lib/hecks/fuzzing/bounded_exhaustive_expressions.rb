require_relative "../bluebook/expression/resolver"
require_relative "../bluebook/expression/evaluator"

module Hecks
  module Fuzzing
    # Phase 7 (equivalence-gap plan) — the one place in this codebase a
    # genuine "true for all inputs," not merely "true for every input we
    # happened to sample," claim is realistically achievable:
    # `Hecks::Bluebook::Expression::{Evaluator,Resolver}`. It's finite-
    # grammar and side-effect-free (Evaluator::PROJECTION/Resolver's own
    # `interpret` never touch a database, a clock, or randomness), but NOT
    # small enough for naive enumeration — ~20 node-producing constructs
    # across two mutually-recursive grammar layers, unbounded recursion
    # through dotted `Lookup` paths, `Addition`, and nested block
    # predicates (`Resolver → Evaluator → Resolver → …`). A flat "every
    # string up to length N" or "every node combination up to depth N with
    # no type filter" explodes well past anything runnable long before
    # depth 3 (two bugs this session lived in exactly this sublanguage —
    # the `formerly_known_as`/`unmark_scalar` family, and the
    # `canonical_form.rb` aliasing bug — neither would have been caught by
    # sampling alone, which is the whole reason this phase exists).
    #
    # TYPE-DIRECTED, not exhaustive-over-strings: this generator only ever
    # recurses into a sub-expression whose OWN type the surrounding
    # construct actually accepts (never `"x".modulo(true)`) — mirroring,
    # by hand, the same admitted-receiver-class tables `Resolver`'s own
    # `interpret` enforces at runtime (`SizedType`/`ToStringType`/
    # `IncludeHaystack` from vocabulary.bluebook, plus the ad hoc
    # `is_a?`/`respond_to?` checks `numeric`/`size_of`/`string_of`/etc.
    # apply that vocabulary.bluebook itself doesn't declare). Restricted
    # to a small representative literal palette (TYPE_LEAVES, below) and a
    # small synthetic attribute set per type (SYNTHETIC_ATTRS), bounded to
    # MAX_DEPTH — that combination is what keeps this tractable (thousands
    # to tens of thousands of cases, not millions) while still being a
    # real, defensible "proven for every well-typed expression up to depth
    # 3" claim for exactly the sublanguage that already bit this project
    # twice.
    #
    # WHAT "PROVEN" MEANS HERE, PRECISELY: every expression this generator
    # produces is well-typed BY CONSTRUCTION (every sub-expression's type
    # matches what its parent construct actually accepts, per this file's
    # own TYPE_RULES). Interpreting a well-typed expression must never
    # raise anything OTHER than `Hecks::Bluebook::Expression::
    # EvaluationError` — that class alone is the sublanguage's own real
    # refusal vocabulary (a divisor that happens to be zero, a `Lookup`
    # this run's synthetic state doesn't happen to carry); anything else
    # escaping (a raw `TypeError`/`NoMethodError`/`ZeroDivisionError`) is
    # exactly the crash-signature this whole file's own header comments
    # (resolver.rb, block_predicates.rb) name as the historical bug class
    # this sublanguage keeps almost-but-not-quite avoiding. This does NOT
    # prove the interpreter computes the SEMANTICALLY right answer (that
    # needs a second, independent oracle — out of scope here, exactly the
    # way rust_conformance_fuzz_spec.rb is the cross-RUNTIME half of this
    # same idea) — only that it never crashes on well-typed input.
    module BoundedExhaustiveExpressions
      module_function

      # `:numeric` deliberately covers BOTH Integer and Float — the
      # resolver's own `numeric`/`require_number` never distinguish them
      # (resolver.rb) — so a generator that kept them as separate types
      # would be modeling a distinction the grammar itself doesn't make.
      TYPES = %i[numeric string boolean array nil_type].freeze

      # THE PALETTE — deliberately small (this file's own header: "a small
      # representative literal palette," matching the plan's own `{0, 1,
      # -1}` example). Widening it doesn't test a different SHAPE of
      # expression, only more values through the same shapes — real
      # boundary-value coverage (Bignum, NaN, empty string, unicode) is
      # PRD 05's job (spec/runtime/numeric_boundary_spec.rb,
      # ValueGenerator's own edge-case tables), not this generator's.
      TYPE_LEAVES = {
        numeric:  ["0", "1", "-1"].freeze,
        string:   ['""', '"a"'].freeze,
        boolean:  %w[true false].freeze,
        nil_type: %w[nil].freeze
      }.freeze

      # TWO SYNTHETIC ATTRIBUTES PER TYPE (the plan's own "2-3 fake
      # attributes per type") — real names are irrelevant to `Resolver
      # .parse` (it never touches state/attrs at all, confirmed directly:
      # only `Lookup#interpret` does) and irrelevant to `interpret` beyond
      # needing to resolve against WHATEVER synthetic state this file
      # supplies (`synthetic_state`, below) — so any non-colliding,
      # non-suffix-shaped name works. Never named the same as a
      # `BLOCK_PARAM` (below) — `Resolver#fetch`'s own `attrs`-wins-over-
      # `state` precedence means a block parameter SHADOWS a same-named
      # top-level attribute for the span of its own predicate, a real
      # hazard this file sidesteps by construction rather than exercising
      # it here (a real, cited resolver.rb hazard, not a gap in THIS
      # generator's own coverage claim).
      SYNTHETIC_ATTRS = {
        numeric: %w[num_a num_b].freeze,
        string:  %w[str_a str_b].freeze,
        boolean: %w[bool_a bool_b].freeze,
        array:   %w[arr_num arr_str].freeze
      }.freeze

      # `arr_num`/`arr_str` — ELEMENT type per array attribute, needed so
      # a block predicate's own bound parameter (`BLOCK_PARAM`, below) is
      # generated against the right leaf/production set for whatever it's
      # actually bound to.
      ARRAY_ELEMENT_TYPE = { "arr_num" => :numeric, "arr_str" => :string }.freeze

      BLOCK_PARAM = "el".freeze

      MAX_DEPTH = 3

      # `state`/`attrs` — a plain Hash satisfies BOTH (confirmed directly:
      # `Resolver#known?` degrades to a bare index check when `state`
      # doesn't `respond_to?(:key?)`, and `fetch` only ever needs
      # `attrs.key?`/`attrs[]`.). Split ACROSS both, matching a real
      # dispatch's own shape (some names come from the record's stored
      # state, some from the command's own args) — not load-bearing for
      # THIS proof (attrs wins regardless), but keeps the synthetic input
      # closer to what `Admissibility` actually builds, in case anything
      # here is reused for a future deeper check.
      #
      # THE VO-VS-SCALAR UNWRAP CASE, DELIBERATELY EXERCISED — half of
      # `num_a`/`str_a`/`bool_a`/one array attribute's elements are bare
      # scalars, the other half (`num_b`/`str_b`/`bool_b`/the other
      # array's elements) are wrapped `{value: X}` — the single-field
      # Value Object shape `Resolver#unwrap_scalar` auto-collapses.
      # resolver.rb's own most serious historical bug in this file (the
      # "UPDATE 2026-08-18" comment: a dotted walk that landed on an
      # un-unwrapped VO compared `false` against every literal, SILENTLY,
      # never raising) lived exactly at this boundary — a generator that
      # only ever supplied bare scalars would never exercise the code
      # path that bug lived in at all.
      # `SingleFieldVO` — NOT a plain Hash, deliberately: `Resolver
      # #unwrap_scalar`'s own guard is `value.respond_to?(:to_h) &&
      # !value.is_a?(Hash) && !value.is_a?(Array)` — it exists
      # specifically to collapse a real hydrated `Runtime::Value`
      # instance (which responds to `#to_h` but is never itself a bare
      # Hash) down to its lone scalar field, and just as deliberately
      # leaves an ACTUAL Hash alone (a genuinely un-hydrated, multi-
      # field record has no single scalar to collapse to). A first
      # version of this generator's own synthetic state used plain
      # `{value: X}` Hashes to stand in for a single-field VO — which
      # `is_a?(Hash)` is true for, so `unwrap_scalar` correctly left them
      # WRAPPED, and every VO-typed synthetic attribute then failed
      # `Addition`/`Compare`/every scalar-typed operation with "expects a
      # number, got {\"value\":5}" — a bug in THIS generator's own
      # synthetic state, not in `Resolver`, caught only by noticing that
      # `num_b == 5` (`num_b` a plain `{value: 5}` Hash) evaluated to
      # `false` instead of `true` before this fix.
      SingleFieldVO = Struct.new(:value) do
        def to_h = { value: value }
      end

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

      def synthetic_attrs = {}

      # `leaves(type, depth)` — every TERMINAL (non-recursive) expression
      # of `type`: the fixed literal palette plus every synthetic
      # attribute NAME declared for that type (never their VALUES — this
      # generates TEXT, the same source a real `given`/`invariant` author
      # would write; `synthetic_state`, above, is what gives those names
      # meaning at `interpret` time).
      def leaves(type)
        (TYPE_LEAVES[type] || []) + (SYNTHETIC_ATTRS[type] || []) + Array(bound_leaves[type])
      end

      # A STACK, not a single slot — a NESTED block predicate (the real
      # corpus already does this two levels deep, roster.bluebook's own
      # `seats.any? { |s| assignments.none? { |a| … } }`) pushes a second
      # bound leaf while the outer one is still active. Both share the
      # SAME `BLOCK_PARAM` spelling ("el") — real Ruby block-parameter
      # shadowing (the inner `el` simply shadows the outer one within its
      # own predicate text), which this generator treats as legal on
      # purpose: `resolver.rb`'s own `interpret_with_element` binds fresh
      # `attrs.merge(param => element)` per level regardless of what the
      # outer level already bound, so a shadowed name still interprets
      # correctly — this generator is proving "does it crash," not "is
      # every generated predicate semantically distinct."
      def bound_leaves = @bound_leaves ||= Hash.new { |h, k| h[k] = [] }

      def with_element_leaf(element_type)
        bound_leaves[element_type] << BLOCK_PARAM
        cache.delete_if { |(type, _depth), _| type == element_type }
        yield
      ensure
        bound_leaves[element_type].pop
        cache.delete_if { |(type, _depth), _| type == element_type }
      end

      # `productions(type, depth)` — every expression of `type` reachable
      # in AT MOST `depth` recursive steps, MEMOIZED (the same sub-
      # expression set is reused at every enclosing recursion, so without
      # memoizing, cost would compound multiplicatively per level instead
      # of additively). `depth` 0 is exactly `leaves(type)`; each
      # increment adds every construct THIS FILE'S OWN TYPE_RULES (below)
      # says can produce `type`, built from `depth - 1` sub-expressions.
      def productions(type, depth)
        cache[[type, depth]] ||= begin
          base = leaves(type)
          depth <= 0 ? base : (base + recursive_productions(type, depth)).uniq
        end
      end

      def cache = @cache ||= {}

      def recursive_productions(type, depth)
        case type
        when :numeric  then numeric_productions(depth)
        when :string   then string_productions(depth)
        when :boolean  then boolean_productions(depth)
        when :array    then array_productions(depth)
        # no recursive producer of nil in this grammar — Find's "not found" is a
        # runtime OUTCOME, not a distinct construct to render as source text
        when :nil_type then []
        else raise ArgumentError, "no production rule for type #{type.inspect}"
        end
      end

      # EVERY internal use of a sub-expression LIST (as opposed to the
      # single final list `productions(type, depth)` returns to its own
      # caller) goes through this, not `productions` directly — the
      # actual thing that made an early version of this generator explode
      # past a million cases by depth 3 wasn't `pairs`' own cross product
      # (already sampled) but the dozen-plus LINEAR `flat_map`/`map`
      # passes `boolean_productions` alone makes over `str`/`num`/`sub` —
      # each individually harmless, but an unbounded few-thousand-item
      # list run through a dozen of them, feeding the NEXT depth's own
      # dozen passes, compounds fast. Bounding every INPUT list (not the
      # final output) keeps the shape diversity `sample`'s even-spacing
      # already preserves while keeping growth roughly linear in depth
      # instead of combinatorial.
      def bounded(type, depth) = sample(productions(type, depth))

      # NUMERIC ← Addition(numeric, numeric) | Modulo(numeric, numeric) |
      # Size(sized) | First/Last(numeric array). `Size` returns an
      # Integer for a String OR an Array receiver alike (`SizedType` —
      # `size_of`, resolver.rb) — both sides generated here.
      def numeric_productions(depth)
        sub = bounded(:numeric, depth - 1)
        # `Modulo`'s own RECEIVER (not its argument — that side already
        # goes through `Resolver#matching_paren`'s own fresh, self-
        # contained re-parse, confirmed safe for any numeric shape
        # including another `Addition`/`Modulo`) has the identical
        # "`Addition` mis-parsed as a suffix receiver" hazard
        # `resolver_numeric_leaves`'s own comment documents for `.to_s`/
        # `.positive?` — `Resolver.parse` tries `split_addition` BEFORE
        # `match_call`, so `"0 + 0.modulo(1)"` (meant as `(0 + 0)
        # .modulo(1)`) actually parses as `0 + (0.modulo(1))`. Restricted
        # to `resolver_numeric_leaves` on the RECEIVER side only — the
        # argument stays the full, unrestricted numeric set.
        pairs(sub).map { |a, b| "#{a} + #{b}" } +
          cross(resolver_numeric_leaves(depth - 1), sub).map { |a, b| "#{a}.modulo(#{b})" } +
          bounded(:string, depth - 1).map { |s| "#{s}.size" } +
          bounded(:array, depth - 1).map { |a| "#{a}.size" } +
          sample(numeric_array_productions(depth - 1)).flat_map { |a| ["#{a}.first", "#{a}.last"] }
      end

      # A "boolean" IN RESOLVER'S OWN SENSE — safe to embed as the
      # RECEIVER of a trailing Resolver-level suffix (`.to_s`, and
      # anywhere else a boolean-typed VALUE, as opposed to a boolean-
      # typed EXPRESSION, is wanted). FOUND LIVE, the same way the
      # nested-`.modulo` bug was: `Resolver.parse` has NO KNOWLEDGE of
      # `==`/`<`/`&&`/`||`/leading `!`/`.include?` AT ALL — those are
      # `Evaluator`'s OWN, entirely separate parsing layer, stripped off
      # BEFORE anything reaches `Resolver.parse` at all (confirmed
      # directly: `Resolver.parse("str_b < str_a")` — no `.` anywhere in
      # that text for any suffix regex to anchor on — falls through
      # every leaf regex to the `Lookup` catch-all, exactly like the
      # nested-modulo bug did). `bounded(:boolean, depth)`'s FULL set
      # includes `Compare`/`Include`/`Or`/`And`/`Not` — genuinely boolean-
      # TYPED at `interpret` time, but `Evaluator`-level SYNTAX, not
      # something `Resolver.parse` can ever recognize as a receiver no
      # matter how it's parenthesized (confirmed directly too: `Resolver
      # .parse` never strips parens at all — `"(3)"` alone already fails
      # to resolve). This is a REAL, PERMANENT boundary of the actual
      # grammar (this whole sublanguage's own two-layer split, not a
      # limitation to work around) — a `given`/`invariant` author simply
      # cannot write `(a < b).to_s` in this language, ever, no matter how
      # they punctuate it. So this generator doesn't either: only
      # RESOLVER-LEVEL boolean-producing constructs (bare literals/
      # lookups, `SignTest`, `Empty`, `Presence`, `MatchesRegex`,
      # `StartsWith`/`EndsWith`, `BlockPredicate` — every one of them
      # parsed via a suffix regex INSIDE `Resolver.parse` itself, per
      # this generator's own design report) are eligible here.
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

      # A "numeric" IN RESOLVER'S OWN SENSE — `Addition`'s twin of
      # `resolver_boolean_leaves`'s own restriction, found the identical
      # way: `"0 + 0.to_s"` (meant as `(0 + 0).to_s`) actually parses as
      # `0 + (0.to_s)`, because `Resolver.parse` tries `split_addition`
      # BEFORE `.to_s`'s own suffix regex in its dispatch order — the `+`
      # "wins" the split before the suffix ever gets a chance to anchor
      # on its own receiver boundary. Confirmed to have zero real-corpus
      # precedent either (`grep`, no `bluebook` file anywhere chains a
      # method or sign-test onto a parenthesized addition) — the same
      # verdict as `resolver_boolean_leaves`'s own comparisons/`&&`/`||`:
      # a real permanent grammar boundary (`Resolver.parse` never strips
      # parens, confirmed directly, so no amount of punctuation rescues
      # `(a + b).to_s`), not a bug to fix in the resolver for a shape
      # nothing has ever needed. `Modulo`/`Size`/`First`/`Last` stay IN
      # (each is its own trailing `.method(...)`/`.method` call, so
      # `Resolver.parse`'s greedy `(.+)\.suffix\z` regexes correctly
      # isolate them as a receiver regardless of what precedes them —
      # only bare top-level `+` has this problem).
      def resolver_numeric_leaves(depth)
        return leaves(:numeric) if depth <= 0

        # SELF-referential on purpose, one depth down — `Modulo`'s own
        # receiver needs the SAME restriction `resolver_numeric_leaves`
        # exists to express in the first place (see its own header
        # comment); the argument stays the full, unrestricted set, same
        # as `numeric_productions`' identical split right above.
        leaves(:numeric) +
          cross(resolver_numeric_leaves(depth - 1), bounded(:numeric, depth - 1)).map { |a, b| "#{a}.modulo(#{b})" } +
          bounded(:string, depth).map { |s| "#{s}.size" } +
          bounded(:array, depth).map { |a| "#{a}.size" } +
          sample(numeric_array_productions(depth)).flat_map { |a| ["#{a}.first", "#{a}.last"] }
      end

      # STRING ← ToS(numeric | boolean | nil | string) | First/Last(string
      # array). `Split` produces an ARRAY, never a String (resolver.rb's
      # own `apply_split`) — deliberately NOT listed as a string producer
      # here; that would be exactly the "vocabulary-legal but grammar-
      # can't-actually-produce-it" mistake this sublanguage's own
      # `ArrayLiteral` bug (§1 of this generator's own design report) was
      # found from, inverted.
      def string_productions(depth)
        sample(resolver_numeric_leaves(depth - 1)).map { |n| "#{n}.to_s" } +
          sample(resolver_boolean_leaves(depth - 1)).map { |b| "#{b}.to_s" } +
          bounded(:nil_type, depth - 1).map { |n| "#{n}.to_s" } +
          bounded(:string, depth - 1).map { |s| "#{s}.to_s" } +
          sample(string_array_productions(depth - 1)).flat_map { |a| ["#{a}.first", "#{a}.last"] }
      end

      # ARRAY ← Split(string, separator) | ArrayLiteral[same-type
      # elements] | the synthetic array attributes (already in `leaves`).
      # Kept deliberately small relative to numeric/string/boolean —
      # `array` is overwhelmingly a RECEIVER type in this grammar (`.size`
      # /`.any?`/`.include?`/…), rarely a produced VALUE; the two real
      # producers are enough to exercise every array-typed consumer
      # elsewhere in this file at least once via a non-leaf path.
      def array_productions(depth)
        return [] if depth <= 0

        bounded(:string, depth - 1).map { |s| "#{s}.split(\",\")" } +
          [numeric_array_literal(depth - 1), string_array_literal(depth - 1)]
      end

      def numeric_array_literal(depth) = "[#{bounded(:numeric, depth).first(2).join(', ')}]"
      def string_array_literal(depth)  = "[#{bounded(:string, depth).first(2).join(', ')}]"

      # Arrays KNOWN (by construction, not merely by type) to hold numeric
      # elements — the two synthetic array attributes (`ARRAY_ELEMENT_TYPE`
      # tags `arr_num`) plus any numeric-array LITERAL this same depth
      # budget can build. `.first`/`.last`/block predicates need to know
      # the ELEMENT type, which plain `array_productions` doesn't carry —
      # this (and `string_array_productions`, its twin) is how that extra
      # bit of type information flows without inventing a second, richer
      # AST just to carry it.
      def numeric_array_productions(depth)
        ["arr_num", numeric_array_literal(depth)]
        # a Split of a string never yields numeric elements — no third
        # entry here, deliberately, not omitted by oversight (see
        # `string_array_productions`, its non-empty twin, right below).
      end

      def string_array_productions(depth)
        ["arr_str", string_array_literal(depth)] + bounded(:string, depth).map { |s| "#{s}.split(\",\")" }
      end

      # BOOLEAN ← every comparison/predicate construct in the grammar.
      # This is where almost all of the sublanguage's OWN real surface
      # lives — a `given`/`invariant`/`ensures` body is ALWAYS boolean-
      # typed at its own top level (`Evaluator.truthy?`), so this is also
      # the set `all_predicates` (below) draws its top-level cases from
      # directly.
      # One declarative table of boolean productions, not several
      # unrelated things bolted together — each `+`-joined term is a
      # distinct grammar rule, and several carry their own comment
      # explaining a specific inclusion/exclusion choice (the
      # `resolver_numeric_leaves`-not-`num` note above, `arr_num`'s non-
      # empty twin, etc). Extracting terms into separate methods would
      # need `sub`/`num`/`str` threaded into each as parameters and
      # would separate every rule from the comment justifying it.
      # rubocop:disable-next Metrics/AbcSize
      def boolean_productions(depth)
        sub = bounded(:boolean, depth - 1)
        num = bounded(:numeric, depth - 1)
        str = bounded(:string, depth - 1)

        pairs(num).map { |a, b| "#{a} == #{b}" } +
          pairs(num).map { |a, b| "#{a} > #{b}" } +
          pairs(str).map { |a, b| "#{a} == #{b}" } +
          pairs(str).map { |a, b| "#{a} < #{b}" } +
          # `resolver_numeric_leaves`, not the raw `num` `==`/`>` above
          # safely use — SignTest's own suffix match
          # (`match_suffix`/`.positive?` et al.) is a plain trailing-
          # string strip, not `Evaluator`'s comparison-scanning, so an
          # `Addition` in `num` would hit the exact "`0 + 0.to_s`" mis-
          # split this generator's own `resolver_numeric_leaves` comment
          # documents (`"0 + 0.positive?"` would parse as `0 + (0
          # .positive?)`, not `(0 + 0).positive?`).
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

      # `.all?`/`.any?`/`.none?` over EACH known-element-typed array
      # source, with a predicate body drawn from `boolean_productions` at
      # ONE LESS depth, evaluated against `BLOCK_PARAM` bound to the
      # array's own element type — this is the ONLY place `Resolver` and
      # `Evaluator` are truly mutually recursive (a `BlockPredicate`'s own
      # `predicate` field is a full `Evaluator` AST, not a `Resolver`
      # leaf — confirmed directly), and the only construct in this whole
      # generator that can nest into ANOTHER block predicate (the real
      # corpus already does this two levels deep —
      # `examples/roster/bluebook/roster.bluebook`'s own `seats.any? { |s|
      # assignments.none? { |a| … } }`).
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

      # The predicate body a block gets — `boolean_productions`, but with
      # `BLOCK_PARAM` (bound to `element_type`) ALSO admitted as a leaf,
      # since inside the block it is exactly as usable as any other
      # `Lookup` name (resolver.rb's own `interpret_with_element`: the
      # bound element joins `attrs` for the span of one evaluation, no
      # different from a top-level attribute — confirmed directly).
      # `sample`d for the same reason every other internal list is — this
      # feeds THREE more constructs per body (`all?`/`any?`/`none?`) times
      # FOUR array sources, so an unbounded body list here is exactly the
      # kind of multiplier this file's own `bounded` comment warns about.
      def predicate_bodies(element_type, depth)
        sample(with_element_leaf(element_type) { boolean_productions(depth) })
      end

      # `haystack.include?(needle)` — String haystack needs a String
      # needle (raises otherwise, evaluator.rb's own `includes?`); Array
      # haystack admits ANY needle type (compared via `equal?`, itself
      # numeric-coerced-first). Both sides generated here, matching
      # `Vocabulary::IncludeHaystack` exactly.
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

      # SAMPLED, NOT A FULL CROSS PRODUCT — a full `list.product(list)`
      # is what actually explodes this generator (numeric productions
      # alone hit 8000+ by depth 2; squaring THAT for `&&`/`==` pairs is
      # where "tens of thousands" becomes tens of millions). The
      # combinatorics genuinely don't buy proof coverage: proving `Or`/
      # `And`/`Not` themselves never crash needs ONE representative pair
      # per depth (`evaluator.rb`'s own `interpret` does zero type-
      # dependent work for those three — `interpret(left) || interpret
      # (right)`, plain Ruby, no coercion, no receiver-type check at
      # all — so a crash there could only come from LEFT or RIGHT
      # themselves, already covered by testing every operand on its own
      # elsewhere in this same predicate set). `Compare`/`Include`/
      # `Addition`/`Modulo` genuinely DO real per-pair type coercion
      # (`Evaluator.apply`/`less_than`/`Resolver.add`/`apply_modulo`), so
      # THOSE stay covered across every construct SHAPE at every depth —
      # just sampled evenly across each side's own operand set (leaves
      # AND deep productions alike, not just whichever the list happens
      # to enumerate first) rather than every possible pairing of them.
      SAMPLE_CAP = 14

      def sample(list) = list.size <= SAMPLE_CAP ? list : list.each_slice(list.size.fdiv(SAMPLE_CAP).ceil).map(&:first)

      def pairs(list)
        sampled = sample(list)
        sampled.product(sampled)
      end

      # `pairs`' own two-different-lists twin — used wherever the LEFT
      # and RIGHT of a construct have genuinely different safety
      # requirements (`Modulo`'s own receiver vs. argument, below) and
      # squaring the SAME sampled list wouldn't be correct.
      def cross(left, right) = sample(left).product(sample(right))

      # THE FULL SET — every boolean-typed expression up to `MAX_DEPTH`,
      # deduplicated (many shorter expressions are also produced, re-
      # wrapped, at every deeper level — `.uniq` inside `productions`
      # already collapses most of that; this is the final pass over the
      # complete depth-`MAX_DEPTH` set specifically).
      def all_predicates(max_depth = MAX_DEPTH)
        productions(:boolean, max_depth).uniq
      end

      # Interprets one predicate against the shared synthetic
      # state/attrs, returning `{ok: true, result: ...}` on any outcome
      # `Evaluator.call` itself can express (a real true/false answer, OR
      # a clean `EvaluationError` — both are the sublanguage WORKING
      # correctly, never a finding) and `{ok: false, error: ...}` only
      # for anything else escaping — the one shape this whole file exists
      # to prove never happens for well-typed input.
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
