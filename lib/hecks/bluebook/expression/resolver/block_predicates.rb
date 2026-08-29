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
module Hecks
  module Bluebook
    module Expression
      # Reopens the SAME `Resolver` module resolver.rb defines — see this
      # file's own header comment above for why the block-predicate/find
      # family lives here rather than in resolver.rb itself.
      module Resolver
        # `receiver.all? { |x| PREDICATE }` / `.any? { ... }` / `.none? {
        # ... }` -- vendored addition, not (yet) upstream hecks
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

        # Every suffix that opens a `{ |x| ... }` block, `.find` included
        # -- shared by `parse_block_opener` below, and by nothing else
        # (this is NOT `BLOCK_PREDICATE_MODES` — `.find` isn't a mode
        # `evaluate_block_predicate` aggregates through, it builds a
        # `Find` node instead, see below).
        BLOCK_OPENER_SUFFIXES = (BLOCK_PREDICATE_MODES.keys + ["find"]).freeze

        # `.all?`/`.any?`/`.none?`/`.find` -- vendored addition, see the
        # `BlockPredicate`/`Find` structs' own comments above. Matched
        # last among the suffix rules (right before the `Lookup`
        # catch-all) since a block's own predicate text can itself
        # contain almost anything a leaf expression can, including
        # ANOTHER block-opening suffix -- letting every more specific
        # rule above try first avoids this one accidentally swallowing a
        # receiver another rule was meant to parse.
        #
        # ONE combined header regex over ALL FOUR suffixes together,
        # not `.find` and `.all?/any?/none?` scanned separately (that
        # was this file's own first cut, and it broke the moment a
        # block predicate's own predicate text contained a DIFFERENT
        # kind of block-opener than the one being scanned for --
        # `legs.any? { |leg| ... legs.find { |o| ... } ... }` : scanning
        # for `.find` FIRST found the INNER `.find`, not the outer
        # `.any?`, because a non-greedy receiver capture only guarantees
        # the FIRST occurrence of ITS OWN suffix, not the first
        # occurrence of ANY block-opening suffix -- confirmed live via
        # the shipping domain's own re-routing rules, the same
        # "no implicit conversion of Symbol into Integer" signature the
        # original nested-`.any?` bug had, not inferred). Scanning for
        # all four AT ONCE and letting the regex engine's own leftmost
        # match win fixes both directions (`.find` nested in `.any?` OR
        # `.any?` nested in `.find`) with the SAME one rule, since the
        # true receiver never itself contains ANY of these four words
        # followed by `{`.
        #
        # `matching_brace` walks forward counting `{`/`}` depth from
        # there, the same quote-aware, depth-aware discipline
        # `split_addition`/`array_elements` already apply, so a `}`
        # inside a nested block (or a quoted `start_with?` substring)
        # never miscounts. `.find`'s own trailing dotted path (`path`)
        # is captured from whatever follows the closing brace ; every
        # other suffix instead requires nothing follow it at all (the
        # `BlockPredicate` shape, unchanged from before this rewrite).
        def parse_block_opener(expr)
          pattern = /\A(.+?)\.(#{BLOCK_OPENER_SUFFIXES.map { |suffix| Regexp.escape(suffix) }.join('|')})\s*\{\s*\|(\w+)\|\s*/m
          header = expr.match(pattern)
          return nil unless header

          receiver_text = header[1]
          suffix = header[2]
          param = header[3]
          body_start = header.end(0)
          body_end = matching_brace(expr, body_start)
          return nil unless body_end

          predicate = Evaluator.parse(expr[body_start...body_end].strip)

          if suffix == "find"
            trailing = expr[(body_end + 1)..].strip
            return nil unless trailing.empty? || trailing.start_with?(".")

            Find.new(receiver: parse(receiver_text), param: param, predicate: predicate,
                     path: trailing.empty? ? [] : trailing[1..].split("."))
          else
            return nil unless expr[(body_end + 1)..].strip.empty?

            BlockPredicate.new(mode: BLOCK_PREDICATE_MODES.fetch(suffix), receiver: parse(receiver_text),
                               param: param, predicate: predicate)
          end
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
          raise EvaluationError, "#{node.mode}? expects a list, got #{describe(collection)}" unless collection.is_a?(Array)

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
