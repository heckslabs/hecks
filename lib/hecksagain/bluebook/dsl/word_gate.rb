require_relative "generic_dispatch"
module Hecksagain
  module Bluebook
    module DSL
      # THE RUBY-SIDE `word_gate` (`rust/parser/src/parse/mod.rs`'s own,
      # read there first — this is the same job, one level up: Rust's own
      # gate refuses a mistyped/inadmissible WORD directly, at the
      # moment it reads a line of `.bluebook` SOURCE TEXT, before any
      # per-construct parsing runs. Ruby never lexes source text — a
      # `.bluebook` file IS Ruby, so `given("x")` is ALREADY a real
      # method call by the time any of this code runs, and Ruby's own
      # method dispatch already refuses an ARITY mismatch on an
      # EXISTING method for free. What Ruby's own dispatch does NOT do
      # is consult the self-hosted grammar table AT ALL — a mistyped
      # word (`giv3n("x")`) or a word used in the wrong context
      # (`identified_by` inside a `command` block) just raises Ruby's
      # own generic `NoMethodError`, naming nothing about what the
      # language actually admits. This module closes that gap.
      #
      # `method_missing`/`respond_to_missing?` ONLY — a word this
      # builder class already answers with an ordinary `def` (or a
      # shared mixin method like `AttributeCollector#attribute`) never
      # reaches this module at all; Ruby's own method lookup finds it
      # first, and item #13's later slices haven't removed every one of
      # those yet. This WAS "zero behavior change for every currently-
      # valid line in the entire corpus" in its own first slice — since
      # item #13's full metaprogrammed dispatch (slice 1, whole-project
      # table-unification survey) started REMOVING the hand-written
      # methods this module's own admissibility check used to defer to,
      # some words now execute for real here too, via `GenericDispatch`
      # — see that module's own header for exactly which ones, and the
      # full account of what was verified before each was migrated. A
      # mistyped or wrongly-contexted word still gets the same real,
      # helpful, table-driven refusal Rust's own `word_gate` already
      # gives, instead of Ruby's own generic `NoMethodError` — that half
      # is genuinely unchanged.
      #
      # `self.class::GRAMMAR_CONTEXT` — each including class names which
      # row of the self-hosted `Context` closed set it corresponds to
      # (`AggregateBuilder::GRAMMAR_CONTEXT = "Aggregate"`, etc.) — the
      # SAME string `word_gate`'s own `context` parameter already is on
      # the Rust side, read off the identical table.
      #
      # BOOTSTRAPPING GATED, the same reason `RuleReference#lookup`
      # already is (`rule_reference.rb`'s own comment has the full
      # story) — the meta-domain's own bootstrap calls dozens of
      # keywords on itself before its own grammar table exists to
      # check them against. For most words, this module steps aside
      # entirely during bootstrap (`super`, Ruby's own ordinary
      # `NoMethodError`) — the exact behavior every builder already had
      # before this module existed, and (unlike `RuleReference`) there
      # is deliberately no fallback covering the whole ~200-row table —
      # that would defeat the entire point.
      #
      # ONE NARROW EXCEPTION, added in item #13's full metaprogrammed
      # dispatch (slice 3, whole-project table-unification survey):
      # `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`, a SMALL, EXPLICIT
      # table naming the same (context, word) -> method pairs the real
      # `calls:` column would say once it exists — used ONLY for words
      # BOTH migrated to the `calls:` shape AND bootstrap-reachable
      # (`attribute`, today). This is the one place in this whole arc a
      # bootstrap fallback was worth building despite `RuleReference`'s
      # own precedent against it: it duplicates NO logic, only a METHOD
      # NAME — `attribute_impl`'s own real, hand-written body is called
      # either way, bootstrap or not, so there is nothing here that can
      # drift the way a full behavioral duplicate could.
      module WordGate
        # PRIVATE, matching Ruby's own convention for both (`Object`
        # defines them private too) — and load-bearing here, not just
        # style: `spec/syntax_conformance_spec.rb`'s "declares every
        # word X answers" check walks `public_instance_methods`, and a
        # public `method_missing`/`respond_to_missing?` would show up
        # there as two more "answered words" no row of the grammar ever
        # declares, on every builder this module touches.

        private

        def method_missing(word, *args, **kwargs, &block)
          if MetaValidator.bootstrapping?
            target = GenericDispatch::BOOTSTRAP_CALLS_FALLBACK[[self.class::GRAMMAR_CONTEXT, word.to_s]]
            return send(target, *args, **kwargs, &block) if target

            return super
          end

          context = self.class::GRAMMAR_CONTEXT
          rows = MetaValidator::SyntaxBoot.call
          keywords = rows[:keywords]
          admitted = keywords.select { |row| row[:context] == context && (row[:word] == word.to_s || row[:was] == word.to_s) }

          return super if admitted.empty? && !admitted_anywhere?(keywords, word)

          if admitted.empty?
            legal = keywords.select { |row| row[:context] == context }.map { |row| row[:word] }.uniq.sort
            raise Malformed,
                  "'#{word}' is not a word #{context} admits — legal words here: #{legal.join(', ')}"
          end

          # ITEM #13's FULL METAPROGRAMMED DISPATCH — the word IS
          # admitted here, and this builder has no hand-written method
          # left for it; before falling through to the "not yet
          # implemented" refusal every word without one still gets,
          # offer it to GenericDispatch — the SAFE, verified subset of
          # words whose whole behavior is now executed off this same
          # table, not just checked against it.
          dispatched = GenericDispatch.try(self, context, word.to_s, args, kwargs, block, rows)
          return dispatched unless dispatched.equal?(GenericDispatch::NOT_HANDLED)

          raise Malformed,
                "'#{word}' is admitted by #{context}'s own grammar, but #{self.class} has no " \
                "builder method for it yet — not yet implemented"
        end

        def respond_to_missing?(word, include_private = false)
          return super if MetaValidator.bootstrapping?

          context = self.class::GRAMMAR_CONTEXT
          MetaValidator::SyntaxBoot.call[:keywords]
                                   .any? { |row| row[:context] == context && (row[:word] == word.to_s || row[:was] == word.to_s) } || super
        end

        # A word admitted SOMEWHERE, just not in THIS context, still
        # falls through to Ruby's own `NoMethodError` rather than this
        # module's own richer refusal — `method_missing` fires for
        # every typo in the whole codebase (this class's own genuinely
        # private helper methods included), not just DSL keyword calls;
        # only raise the RICH, table-driven message when the word is at
        # least SOMETHING the grammar knows about, anywhere, so an
        # unrelated Ruby-level typo inside a builder's own private code
        # keeps its own ordinary, unconfusing `NoMethodError`.
        def admitted_anywhere?(rows, word)
          rows.any? { |row| row[:word] == word.to_s || row[:was] == word.to_s }
        end
      end
    end
  end
end
