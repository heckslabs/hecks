require_relative "generic_dispatch"
module Hecks
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
      #
      # TWO FURTHER PIECES, both slice 5:
      #   - `word_gate_dispatch` is the same admission+dispatch logic
      #     `method_missing` below runs, factored out so a class with
      #     its OWN class-level `method_missing` (`HecksagonBuilder`'s/
      #     `WorldBuilder`'s genuinely open-ended verb vocabulary) can
      #     call it directly and fall back to its own open-verb handling
      #     only when this returns `NOT_ADMITTED` — a class-level `def`
      #     always wins over an included module's in Ruby's own method
      #     resolution, so their OWN `method_missing` is the only one
      #     that ever runs for them, and this is what lets a real,
      #     closed-set word (`port`/`realm`/`latest`) still reach
      #     `GenericDispatch` despite that.
      #   - the "Type"-position fallback inside `word_gate_dispatch`
      #     itself, for `one_of`/`list_of` — called inside an
      #     attribute's own type argument, with `self` as whatever
      #     builder is currently `instance_eval`ing, never a dedicated
      #     "Type" builder `self.class::GRAMMAR_CONTEXT` could ever
      #     name. See that method's own comment.
      module WordGate
        # A caller with its OWN class-level `method_missing`
        # (`HecksagonBuilder`/`WorldBuilder` — see `word_gate_dispatch`'s
        # own header) checks for this to tell "not a word the grammar
        # admits at all" apart from every other outcome below (a real
        # dispatch, or a raised refusal) — never raised itself, so a
        # caller can fall through to its own open-ended handling instead.
        NOT_ADMITTED = Object.new.freeze

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
            fallback = GenericDispatch::BOOTSTRAP_CALLS_FALLBACK
            # Own context first, "Type" second — the same order the
            # ordinary (non-bootstrapping) `word_gate_dispatch` path
            # below checks them in, for the same reason: `list_of`/
            # `one_of` used in an attribute's own type position never
            # arrive with `self.class::GRAMMAR_CONTEXT == "Type"`.
            target = fallback[[self.class::GRAMMAR_CONTEXT, word.to_s]] || fallback[["Type", word.to_s]]
            return send(target, *args, **kwargs, &block) if target

            return super
          end

          result = word_gate_dispatch(word, args, kwargs, block)
          return super if result.equal?(NOT_ADMITTED)

          result
        end

        # THE CORE ADMISSION+DISPATCH LOGIC, factored out of
        # `method_missing` — item #13's full metaprogrammed dispatch
        # (slice 5, whole-project table-unification survey) — so a
        # class with its OWN class-level `method_missing`
        # (`HecksagonBuilder`'s/`WorldBuilder`'s genuinely open-ended
        # verb vocabulary, `persisted_by "Heki"`/`posted_by "Carrier"`,
        # can never BE a closed table) can still route a word THE
        # GRAMMAR ADMITS through here first, falling back to its own
        # open-verb handling only for what this doesn't recognize at
        # all — unblocking `Hecksagon#port`/`World#realm`/`World#latest`,
        # each a real, closed-set word that happened to sit on a class
        # whose own `method_missing` a class-level `def` always wins
        # over Ruby's own module-inclusion order.
        #
        # NEVER RAISES "not admitted" — returns `NOT_ADMITTED` instead,
        # so the caller (this module's own `method_missing`, or one of
        # the two above) decides what that means for it. DOES still
        # raise the richer, table-driven refusals below once a word is
        # admitted-but-unimplemented, or admitted-somewhere-else-only —
        # those are real, useful refusals regardless of which
        # `method_missing` is asking.
        def word_gate_dispatch(word, args, kwargs, block)
          context = self.class::GRAMMAR_CONTEXT
          rows = MetaValidator::SyntaxBoot.call
          keywords = rows[:keywords]
          admitted = keywords.select { |row| row[:context] == context && (row[:word] == word.to_s || row[:was] == word.to_s) }

          # THE TYPE-POSITION FALLBACK — item #13's full metaprogrammed
          # dispatch (slice 5). `one_of`/`list_of`, called inside an
          # attribute's own type argument (`attribute :x,
          # one_of("a","b")`), run with `self` as whatever builder is
          # CURRENTLY instance_eval'ing — there is no dedicated "Type"
          # builder of its own; every attribute()-taking builder answers
          # these identically, through the shared `AttributeCollector`
          # mixin. `self.class::GRAMMAR_CONTEXT` can never actually BE
          # "Type", so a word admitted only there would otherwise look
          # inadmissible everywhere. Checked only once THIS context has
          # already come up empty, so a context with its own same-named
          # row (`ValueObject`'s own `one_of`, the block-wrapper form)
          # keeps using that instead, unaffected.
          if admitted.empty?
            type_admitted = keywords.select { |row| row[:context] == "Type" && row[:word] == word.to_s }
            unless type_admitted.empty?
              admitted = type_admitted
              context = "Type"
            end
          end

          return NOT_ADMITTED if admitted.empty? && !admitted_anywhere?(keywords, word)

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
          keywords = MetaValidator::SyntaxBoot.call[:keywords]
          keywords.any? { |row| row[:context] == context && (row[:word] == word.to_s || row[:was] == word.to_s) } ||
            keywords.any? { |row| row[:context] == "Type" && row[:word] == word.to_s } ||
            super
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
