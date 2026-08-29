require "json"
require_relative "../../vocabulary"

module Hecks
  module Bluebook
    module Expression
      # The boolean/comparison layer of a predicate's expression grammar —
      # parses a canonical predicate string into an Or/And/Not/Compare/
      # Include/Resolve AST (cached per distinct string, `ast_cache`) and
      # interprets it against a call's own state/attrs. Leaf `Resolve`
      # nodes delegate to `Resolver` for the dotted/arithmetic
      # sub-grammar; `OPERATORS` is the comparison table projected from
      # the grammar chapter (`PROJECTION`).
      module Evaluator
        Operator = Struct.new(:symbol, :compares_less_than, :compares_equal, :negated, keyword_init: true)

        # Six operators, reduced to two primitives (less_than, equal) combined
        # with a small boolean algebra: compares_less_than/compares_equal choose
        # which primitive(s) OR together, negated inverts the result.
        #
        # READ, NOT RESTATED. This table is the checked-in projection of the
        # grammar chapter's admitted set (bin/expression_projection), joined with
        # the algebra Vocabulary::Comparison declares. The evaluator cannot
        # boot the chapter that configures it — the Prism adapter normalises
        # every predicate through CanonicalForm while a bluebook loads — so
        # the projection is how the domain reaches here: regenerated when the
        # ledger changes, held fresh by spec/operators_export_spec.rb, and
        # held to the live machinery by spec/operator_conformance_spec.rb.
        PROJECTION = JSON.parse(
          File.read(File.join(__dir__, "projection.json")), symbolize_names: true
        ).freeze

        OPERATORS = PROJECTION.fetch(:operators)
                              .select { |row| row[:category] == "comparison" }
                              .map { |row| Operator.new(**row.slice(:symbol, :compares_less_than, :compares_equal, :negated)) }
                              .freeze

        COMPARISONS = OPERATORS.map(&:symbol).freeze

        # The boolean/comparison grammar an expression parses into. Leaf nodes
        # (Compare/Include/Resolve) hold already-parsed Resolver ASTs, not raw
        # strings — which branch a leaf's grammar takes is, like the boolean/
        # comparison grammar above it, a pure function of the string. Only the
        # final state/attrs dictionary read, inside Resolver.interpret, varies
        # per call. Parsing the whole tree once and caching it (ast_cache,
        # below) is what makes that safe.
        Or      = Struct.new(:left, :right, keyword_init: true)
        And     = Struct.new(:left, :right, keyword_init: true)
        Not     = Struct.new(:node, keyword_init: true)
        Compare = Struct.new(:operator, :left, :right, keyword_init: true)
        Include = Struct.new(:haystack, :needle, keyword_init: true)
        Resolve = Struct.new(:expr, keyword_init: true)

        module_function

        # Keyed by the exact string `call` receives. Canonical text is already
        # normalised at DSL-build time, so the same given/invariant's text is
        # byte-identical across every dispatch that evaluates it — parsed once
        # here, interpreted fresh against each call's own state/attrs. Matches
        # MetaValidator.verdicts' unsynchronized `||= {}` idiom : redundant
        # parse work under real parallelism, never corruption.
        def ast_cache = @ast_cache ||= {}

        def call(expr, state, attrs = {})
          interpret(ast_cache[expr] ||= parse(expr), state, attrs)
        end

        # A refused `given`/`ensures`/`invariant` names its own DESCRIPTION
        # ("not already superseded") but, on its own, not what the block
        # actually evaluated to — the difference between "the rule is right
        # and my data is wrong" and "the rule is subtly wrong" is often just
        # seeing the two operands. Scoped to the single shape that has one
        # honest answer: `expr`'s own TOP-LEVEL node is a bare `Compare` —
        # not `Or`/`And`/`Not` (which of several sub-comparisons would even
        # be "the" one at fault is genuinely ambiguous), `Include` (no
        # left/right to show), or `Resolve` (a bare boolean read, nothing to
        # compare against). Values are rendered with `Rendering.describe`,
        # the same house style every other refusal already prints a value
        # through. Returns `nil` — not raised — on anything else, INCLUDING
        # an operand that itself fails to resolve (`EvaluationError`): a
        # missing diagnostic is a worse debugging experience than none, a
        # crash while building one is worse still.
        def comparison_detail(expr, state, attrs = {})
          node = ast_cache[expr] ||= parse(expr)
          return nil unless node.is_a?(Compare)

          lhs = Resolver.interpret(node.left, state, attrs)
          rhs = Resolver.interpret(node.right, state, attrs)
          "left: #{Resolver.describe(lhs)}, right: #{Resolver.describe(rhs)}"
        rescue EvaluationError
          nil
        end

        def parse(expr)
          expr = strip_parens(expr.to_s.strip)

          left, right = split_top_level(expr, "||")
          return Or.new(left: parse(left), right: parse(right)) if left

          left, right = split_top_level(expr, "&&")
          return And.new(left: parse(left), right: parse(right)) if left

          # Tried BEFORE `.include?`/comparisons, not after — `!` negates
          # the WHOLE boolean expression that follows it (`!names.include?(x)`
          # means `!(names.include?(x))`, never "call .include? on the negated
          # receiver"), so the leading marker has to be stripped and the
          # remainder re-parsed before anything downstream gets a chance to
          # mis-scan across it. It used to sit after `match_include`, whose
          # naive `rindex(".include?(")` has no concept of a leading `!` —
          # for `!names.include?(x)` it swallowed the `!` straight into the
          # haystack text ("!names"), which `Resolver.parse` cannot resolve,
          # so every spelling of negated membership raised instead of
          # evaluating. Moving the check here fixes both the bare prefix
          # (`!names.include?(x)`) and the parenthesized form
          # (`!(names.include?(x))`) — the recursive `parse` call sees the
          # clean remainder and correctly finds the `.include?` (or `&&`/`||`)
          # inside it.
          return Not.new(node: parse(Regexp.last_match(1))) if expr =~ /\A!(.+)\z/

          membership = match_include(expr)
          return Include.new(haystack: Resolver.parse(membership[0]), needle: Resolver.parse(membership[1])) if membership

          OPERATORS.each do |op|
            left, right = split_comparison(expr, op.symbol)
            return Compare.new(operator: op, left: Resolver.parse(left), right: Resolver.parse(right)) if left
          end

          Resolve.new(expr: Resolver.parse(expr))
        end

        def interpret(node, state, attrs)
          case node
          when Or      then interpret(node.left, state, attrs) || interpret(node.right, state, attrs)
          when And     then interpret(node.left, state, attrs) && interpret(node.right, state, attrs)
          when Not     then !interpret(node.node, state, attrs)
          when Compare then compare(node.operator, node.left, node.right, state, attrs)
          when Include then includes?([node.haystack, node.needle], state, attrs)
          when Resolve then truthy?(Resolver.interpret(node.expr, state, attrs))
          else
            # Every node `parse` can produce has a `when` above — a
            # backstop against the day this grammar grows a new node
            # type and `interpret` doesn't grow to match it. A missing
            # arm here used to return bare `nil`, and `Or`/`And` fold
            # that straight into the boolean algebra as ordinary falsy
            # — reading exactly like "the rule legitimately does not
            # hold" rather than "the runtime cannot evaluate this rule
            # at all", the one silent no-op this language otherwise
            # refuses.
            raise EvaluationError, "no interpreter handles #{node.class} — add a case before parse can produce it"
          end
        end

        def compare(comparator, left, right, state, attrs)
          lhs = Resolver.interpret(left, state, attrs)
          rhs = Resolver.interpret(right, state, attrs)

          apply(comparator, lhs, rhs)
        end

        # The algebra itself, on values already resolved — split out so a sign
        # test (SignTest#compares_via names an Operator symbol) can apply the
        # SAME primitives compare() uses against the literal 0, rather than
        # re-deriving positive?/negative?/zero? by hand a second time.
        def apply(comparator, lhs, rhs)
          result = (comparator.compares_less_than && less_than(lhs, rhs)) ||
                   (comparator.compares_equal && equal?(lhs, rhs))
          comparator.negated ? !result : result
        end

        def less_than(lhs, rhs)
          left  = Resolver.numeric(lhs)
          right = Resolver.numeric(rhs)
          return left < right if left && right
          return lhs < rhs    if lhs.is_a?(String) && rhs.is_a?(String)

          raise EvaluationError,
                "comparison of #{class_of(lhs)} with #{Resolver.describe(rhs)} failed"
        end

        def equal?(lhs, rhs)
          left  = Resolver.numeric(lhs)
          right = Resolver.numeric(rhs)
          return left == right if left && right

          lhs == rhs
        end

        def truthy?(value)
          !value.nil? && value != false
        end

        def class_of(value)
          value.nil? ? "nil" : value.class.name
        end

        # THE SAME MIS-SPLIT `Resolver.match_call` had (its own comment
        # has the full story), found here too by the same generator: a
        # `.include?` needle can itself be — or contain — ANOTHER
        # `.include?` call (`"".include?(arr.all? { |el| "".include?("")
        # }.to_s)`, a String built via `.to_s` off a block predicate
        # whose own body happens to include one) — `rindex` finds the
        # INNERMOST occurrence, not the outermost this split actually
        # needs. Fixed identically: try each occurrence left to right,
        # keep the first whose own balanced-paren match reaches the
        # string's last character — `Resolver.matching_paren` is reused
        # directly rather than duplicated, the same depth-tracking rule
        # either grammar layer needs here.
        def match_include(expr)
          start = 0
          marker = ".include?("
          while (index = expr.index(marker, start))
            close = Resolver.matching_paren(expr, index + marker.length)
            return [expr[0...index], expr[(index + marker.length)...close]] if close == expr.length - 1

            start = index + 1
          end
          nil
        end

        # Declared the same way in Vocabulary::IncludeHaystack
        # (language/bluebook/vocabulary.bluebook) — spec/vocabulary_conformance_spec
        # holds this equal to the language, so the set of haystack types
        # `.include?` supports cannot drift from what the language says it
        # does.
        INCLUDE_HAYSTACKS = Hecks::Vocabulary.fetch("IncludeHaystack")

        def includes?(parts, state, attrs)
          haystack, needle = parts
          wanted = Resolver.interpret(needle, state, attrs)

          case (found = Resolver.interpret(haystack, state, attrs))
          when Array then found.any? { |item| equal?(item, wanted) }
          when String
            raise EvaluationError, "no implicit conversion of #{class_of(wanted)} into String" unless wanted.is_a?(String)

            found.include?(wanted)
          else false
          end
        end

        def strip_parens(expr)
          return expr unless expr.start_with?("(") && expr.end_with?(")")

          depth = 0
          expr.each_char.with_index do |char, index|
            depth += 1 if char == "("
            depth -= 1 if char == ")"
            return expr if depth.zero? && index < expr.length - 1
          end
          strip_parens(expr[1..-2].strip)
        end

        def split_top_level(expr, operator)
          index = top_level_index(expr, operator)
          return nil unless index

          [expr[0...index].strip, expr[(index + operator.length)..].strip]
        end

        def split_comparison(expr, operator)
          index = top_level_index(expr, operator) { |at| !part_of_longer?(expr, at, operator) }
          return nil unless index

          [expr[0...index].strip, expr[(index + operator.length)..].strip]
        end

        def part_of_longer?(expr, index, operator)
          after  = expr[index + operator.length]
          before = index.positive? ? expr[index - 1] : nil

          return true if after == "=" && !operator.end_with?("=")
          return true if ["<", ">", "!", "="].include?(before) && operator.start_with?("=")

          false
        end

        def top_level_index(expr, operator)
          depth = 0
          quote = nil
          index = 0

          while index < expr.length
            char = expr[index]

            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            # `{`/`}` depth -- vendored addition, not (yet) upstream
            # hecks (migration plan task 9): this method already
            # treats `(`/`)` as a grouping construct so an operator
            # INSIDE a call's parens is never mistaken for a top-level
            # split point ; `{`/`}` needed the identical treatment the
            # moment `Bluebook::Expression::Resolver` grew block-taking
            # `.all?`/`.any?`/`.none? { |s| PREDICATE }` support (see
            # resolver.rb's own `BlockPredicate` addition) -- without
            # this, an operator INSIDE the block's own predicate (e.g.
            # `s.length > 0`) reads as a top-level split of the WHOLE
            # `value.split("::").all? { |s| s.length > 0 }` expression,
            # confirmed live via `Lexicon::Lexicon.Lookup`/`Query::Query.
            # Run` (the exact `Phrase` invariant this gap was found
            # against) : the stray `>` split the expression in half
            # before `Resolver.parse` ever saw the block as one atomic
            # leaf, and the two halves then failed independently with
            # the same raw `TypeError` the block-predicate fix was
            # built to close. `{`/`}` cannot legitimately appear inside
            # a quoted literal either, so this sits beside the existing
            # paren-depth branch, not instead of it.
            #
            # `[`/`]` -- the identical lesson a THIRD time (found live via
            # the type-directed bounded-exhaustive expression generator,
            # Phase 7 of the equivalence-gap plan): `Resolver::ArrayLiteral`
            # (`[a, b]`) can appear as a general sub-expression, not only
            # as `.include?`'s own haystack, the moment an array-typed
            # attribute or a synthesized literal is embedded anywhere else
            # -- and an element containing a top-level `+`/comparison of
            # its own (`[0, 0 + 0]`) used to read as a split point for
            # THIS expression's own boolean/comparison grammar, exactly
            # the way an un-tracked `{`/`}` once did for block predicates.
            elsif ["(", "{", "["].include?(char)
              depth += 1
            elsif [")", "}", "]"].include?(char)
              depth -= 1
            elsif depth.zero? && expr[index, operator.length] == operator
              return index if !block_given? || yield(index)
            end

            index += 1
          end
          nil
        end
      end
    end
  end
end
