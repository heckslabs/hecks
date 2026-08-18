# HAND-WRITTEN — the block-predicate/find family of the leaf grammar
# (`Bluebook::Expression::Resolver`'s own `.all?`/`.any?`/`.none?`/
# `.find` suffixes), split into this sibling file to keep resolver.rb
# under Metrics/ModuleLength (350) : this reopens the SAME `Resolver`
# module resolver.rb defines, the long nested `module A; module B; ...`
# form (not the compact `A::B` form) so bare constant/method lookups
# here (`EvaluationError`, `Evaluator`, `describe`, `unwrap_scalar`,
# `walk_path`) resolve exactly the way they do inside resolver.rb
# itself — this is one module, split across two files, not two
# modules. See resolver.rb's own header for the grammar this belongs
# to; see each struct/method below for its own "why".
module Hecksagain
  module Bluebook
    module Expression
      module Resolver
        # `receiver.all? { |x| PREDICATE }` / `.any? { ... }` / `.none? {
        # ... }` -- vendored addition, not (yet) upstream hecksagain
        # (migration plan task 9), completing the same `Phrase`
        # four-segment invariant the `Split` node above was built for
        # (`value.split("::").all? { |s| s.length > 0 }`). Structurally
        # different from every other addition in this file: every prior
        # suffix is a flat receiver -> scalar transform, but a block
        # predicate needs to evaluate its own sub-expression ONCE PER
        # ELEMENT with the block parameter bound to that element. Kept
        # minimal per the migration plan's own instruction -- no
        # persistent iteration-variable concept added to Resolver's
        # state model at all ; `predicate` below is a fully-parsed
        # EVALUATOR ast (not a Resolver ast -- the predicate is a
        # boolean/comparison expression like `s.length > 0`, exactly the
        # grammar `Bluebook::Expression::Evaluator` owns, not this
        # module's own leaf grammar), parsed once at `parse`-time same as
        # every sibling node's sub-expressions are. `mode` distinguishes
        # all?/any?/none? without three duplicated node types, since
        # their only difference is which Array predicate aggregates the
        # per-element results (interpret_with_element, below, is the
        # "smallest correct thing" the plan asked for -- it threads the
        # element binding through a temporarily-extended `attrs` hash for
        # that one predicate's evaluation only, never touching
        # `interpret`'s own signature or any other node's call sites).
        # `Resolver` already calls into `Evaluator` elsewhere in this
        # file (`sign_test_node`/`apply_sign_test` call `Evaluator.
        # apply`/`Evaluator::OPERATORS` directly) -- this is the same
        # precedented cross-reference, not a new coupling.
        BlockPredicate = Struct.new(:mode, :receiver, :param, :predicate, keyword_init: true)

        # Which Array method each block-predicate suffix maps to, and
        # which Ruby Enumerable method decides the aggregate result --
        # declared as data, not a three-way `case`, the same shape
        # SIGN_TEST_OPERATORS above already uses for its own suffix
        # family.
        BLOCK_PREDICATE_MODES = {
          "all?"  => :all,
          "any?"  => :any,
          "none?" => :none
        }.freeze

        # `receiver.find { |x| PREDICATE }` / `.find { ... }.a.b` -- the
        # "find-then-project" shape the shipping domain's re-routing
        # rules kept reaching for by hand (a caller-precomputed
        # `next_load_location` field standing in for "the leg after this
        # one", because `BlockPredicate` above can only answer yes/no,
        # never hand back the element it found). `path` holds the
        # dotted segments walked past the closing `}`, e.g. the `["
        # next_load_location"]` in `legs.find { |l| l.load_location ==
        # x }.next_load_location` -- empty when `.find { ... }` is used
        # bare (its own found-element-or-nil is the value, same as any
        # other leaf, e.g. composed with `.present?` the same way every
        # other receiver already composes with it). Reuses `param`/
        # `predicate`'s exact field names from `BlockPredicate` on
        # purpose: `interpret_with_element` below binds by those two
        # names and is shared unchanged between both node types.
        Find = Struct.new(:receiver, :param, :predicate, :path, keyword_init: true)

        module_function

        # `.all?`/`.any?`/`.none?` -- vendored addition, see the
        # `BlockPredicate` struct's own comment above. Matched last among
        # the suffix rules (right before the `Lookup` catch-all) since
        # its own predicate text can itself contain almost anything a
        # leaf expression can -- letting every more specific rule above
        # try first avoids this one accidentally swallowing a receiver
        # another rule was meant to parse. `receiver` and the predicate
        # body are each parsed through their OWN correct grammar --
        # `parse` (this module's leaf grammar) for the receiver, `
        # Evaluator.parse` (the boolean/comparison grammar) for the
        # predicate, since a predicate like `s.length > 0` is a
        # comparison, not a bare leaf.
        # Rewritten to a header-regex-plus-`matching_brace` scan instead
        # of one greedy-to-`\z` regex per suffix -- the original `(.+?)
        # \s*\}\z` shape broke the moment a predicate contained ANOTHER
        # block predicate (`legs.any? { |l| ... legs.any? { |o| ... } }`,
        # the exact re-routing check this grammar gap forced the
        # shipping domain to precompute by hand instead) : looping the
        # three suffixes with a GREEDY receiver capture matched the
        # LAST occurrence of `.suffix? {` in the string, not the
        # outermost one, so the "receiver" swallowed the inner call too
        # and crashed with `TypeError: no implicit conversion of Symbol
        # into Integer`, confirmed live, not inferred. The header regex
        # below instead uses a NON-GREEDY receiver capture across all
        # three suffixes at once, so it stops at the FIRST `.suffix? {`
        # in the string (the real receiver never itself contains one) ;
        # `matching_brace` then walks forward counting `{`/`}` depth,
        # the same quote-aware, depth-aware discipline `split_addition`/
        # `array_elements` already apply, so a `}` inside a nested block
        # predicate (or a quoted `start_with?` substring) never
        # miscounts.
        def parse_block_predicate(expr)
          header = expr.match(/\A(.+?)\.(#{BLOCK_PREDICATE_MODES.keys.map { |suffix| Regexp.escape(suffix) }.join('|')})\s*\{\s*\|(\w+)\|\s*/m)
          return nil unless header

          body_start = header.end(0)
          body_end = matching_brace(expr, body_start)
          return nil unless body_end
          return nil unless expr[(body_end + 1)..].strip.empty?

          BlockPredicate.new(
            mode:      BLOCK_PREDICATE_MODES.fetch(header[2]),
            receiver:  parse(header[1]),
            param:     header[3],
            predicate: Evaluator.parse(expr[body_start...body_end].strip)
          )
        end

        # `receiver.find { |x| PREDICATE }` / `.find { ... }.a.b` -- see
        # the `Find` struct's own comment above. Same header-plus-
        # `matching_brace` shape `parse_block_predicate` uses (find is
        # deliberately not folded into `BLOCK_PREDICATE_MODES` --
        # `evaluate_block_predicate` aggregates a collection to a single
        # boolean via `Enumerable#all?/any?/none?`, `Find` hands back an
        # ELEMENT via `Enumerable#find`, a different return shape
        # entirely, so sharing one node type would mean branching on
        # `mode` for the return type too, exactly the "smallest correct
        # thing, no accidental generality" the `BlockPredicate` struct's
        # own comment already argued against). Not anchored to `\z` --
        # unlike a block predicate, `.find { ... }` is meant to be
        # followed by a dotted projection path, so whatever trails the
        # closing brace is captured as `path` instead of rejecting the
        # parse.
        def parse_find(expr)
          header = expr.match(/\A(.+?)\.find\s*\{\s*\|(\w+)\|\s*/m)
          return nil unless header

          body_start = header.end(0)
          body_end = matching_brace(expr, body_start)
          return nil unless body_end

          trailing = expr[(body_end + 1)..].strip
          return nil unless trailing.empty? || trailing.start_with?(".")

          Find.new(
            receiver:  parse(header[1]),
            param:     header[2],
            predicate: Evaluator.parse(expr[body_start...body_end].strip),
            path:      trailing.empty? ? [] : trailing[1..].split(".")
          )
        end

        # The index of the `}` that closes the `{` implicitly opened
        # just before `start` (the caller's own header match already
        # consumed that opening brace, so depth begins at 1) -- nil if
        # the string runs out before depth returns to 0 (a caller-error
        # shape, not a valid expression). Quote-aware so a `}` inside a
        # quoted substring (`.start_with?("}")`) never miscounts, the
        # same discipline `split_addition`/`array_elements` already
        # apply for their own depth tracking.
        def matching_brace(expr, start)
          depth = 1
          quote = nil
          index = start
          while index < expr.length
            char = expr[index]
            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            elsif char == "{"
              depth += 1
            elsif char == "}"
              depth -= 1
              return index if depth.zero?
            end
            index += 1
          end
          nil
        end

        # `.all?`/`.any?`/`.none?` -- vendored addition, see the
        # `BlockPredicate` struct's own comment above. `collection` is
        # already-interpreted (a real Array, produced by whatever
        # receiver expression came before it -- typically `Split`'s
        # output), so this only has to run the per-element predicate and
        # aggregate. `interpret_with_element` is the "smallest correct
        # thing" the migration plan asked for : no persistent iteration-
        # variable concept added anywhere else in Resolver's state model,
        # just `attrs` extended with the bound name for the span of that
        # one predicate evaluation, discarded immediately after.
        def evaluate_block_predicate(node, collection, state, attrs)
          unless collection.is_a?(Array)
            raise EvaluationError, "#{node.mode}? expects a list, got #{describe(collection)}"
          end

          outcomes = collection.map { |element| interpret_with_element(node, element, state, attrs) }

          case node.mode
          when :all  then outcomes.all?
          when :any  then outcomes.any?
          when :none then outcomes.none?
          end
        end

        # Binds the block parameter for exactly one element's predicate
        # evaluation -- `attrs` wins over `state` in `fetch` (see below),
        # so the bound name shadows any same-named state/attrs field for
        # the span of this one call only ; nothing persists past it.
        def interpret_with_element(node, element, state, attrs)
          Evaluator.interpret(node.predicate, state, attrs.merge(node.param.to_sym => element))
        end

        # `.find { |x| PREDICATE }` -- see the `Find` struct's own
        # comment above. Reuses `interpret_with_element` unchanged
        # (below, shared with `BlockPredicate` — both bind `node.param`
        # to one element and interpret `node.predicate` against it) to
        # find the FIRST element the predicate accepts, then projects
        # `node.path` through it via `walk_path`, the same dotted-
        # segment walk `lookup` uses for a plain attribute path. `nil`
        # (no matching element, or a `path` segment that doesn't
        # resolve) flows through rather than raising — the same "a
        # dispatch-time given just refuses" shape every other missing-
        # value case in this grammar already has, and the one a re-
        # routing check like "is there a leg after this one" needs :
        # not finding one is a normal outcome, not an error.
        def found_of(node, collection, state, attrs)
          raise EvaluationError, "find expects a list, got #{describe(collection)}" unless collection.is_a?(Array)

          found = collection.find { |element| interpret_with_element(node, element, state, attrs) }
          return unwrap_scalar(found) if node.path.empty?
          return nil if found.nil?

          unwrap_scalar(walk_path(found, node.path))
        end
      end
    end
  end
end
