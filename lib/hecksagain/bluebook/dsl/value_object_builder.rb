require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class ValueObjectBuilder
        GRAMMAR_CONTEXT = "ValueObject"

        include AttributeCollector
        include RuleReference
        include WordGate

        def initialize(name, owner_value_objects: [])
          @name       = name
          @invariants = []
          @members    = []
          @owner_value_objects = owner_value_objects
        end

        # THE WRAPPER BLOCK IS GONE (ADR 0025, "Attributes" — "closed sets
        # lose the wrapper block"). `member` lines are bare now, written
        # directly in the `value_object` body with no `one_of do ... end`
        # around them — `build`'s own `closed_set: @closed_set ||
        # !@members.empty?` already treats a non-empty `@members` as closed,
        # so nothing else has to change for that to work. A single-field set
        # has an even shorter spelling: `attribute`'s own `one_of:` keyword
        # (`AttributeCollector#install_inline_closed_set`, overridden below).
        #
        # This also removes a real, documented landmine: the block form
        # collided with `AttributeCollector#one_of`'s own type-position
        # method (`one_of("a", "b")`, different arity) the moment both were
        # mixed into the same builder — a value_object could never actually
        # use the inline form on one of its own attributes. One `one_of`
        # method now, not two.
        #
        # LEGACY UNDER SHADOW-PARSING (S0a's own bridge) — frozen era text
        # still writes the block form (2 locations in
        # `examples/banking/data/eras/banking/1.bluebook`, duplicated once
        # more in that era's own archive copy), so `EraGuard.shadow_parse`
        # still needs to read it. `block_given?` is what tells the two
        # calling shapes apart: the type-position form
        # (`one_of("a", "b")`) never passes a block, only the wrapper does.
        def one_of(*values, &block)
          unless block
            # NO VALUES, NO BLOCK is the SCALAR spelling — nonsensical, not
            # merely inert: it names a closed set with nothing in it. The
            # original block form caught this by a side effect (`@closed_set
            # = true` ran unconditionally, before the `if block`), and this
            # keeps the same refusal rather than letting the call fall
            # through and silently do nothing.
            if values.empty?
              raise Malformed,
                    "#{@name}'s one_of names no values — one_of(\"a\", \"b\") takes at least one, or " \
                    "give the attribute its own one_of: [...] for a named closed set"
            end

            # AttributeCollector's own `one_of(*values)` — Ruby's normal
            # `super` reaches the included module's method from here.
            return super(*values)
          end

          unless MetaValidator.shadow_parsing?
            raise Malformed,
                  "#{@name}'s one_of do ... end wrapper is gone — give the single attribute its " \
                  "own one_of: [...], or write bare member lines with no wrapper for a multi-field set"
          end

          @closed_set = true
          instance_eval(&block)
        end

        # RENAMED FROM `member` — item #13's full metaprogrammed dispatch
        # (slice 4c). Bootstrap-reachable, in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def member_impl(**fields)
          raise Malformed, "#{@name} declared an empty member" if fields.empty?

          @members << fields
        end

        # NO BLOCK is a REFERENCE, not a fresh declaration — the same
        # move S10 already made for `CommandBuilder#given` (ADR 0025,
        # "a precondition shared across commands is declared once... a
        # command references it by name"), one level over: a rule
        # shared across SIBLING value objects on the same aggregate,
        # declared once, on the first one to need it. Real, live
        # redundancy this closes: `Account`'s own `Money`/`PositiveMoney`
        # both declared `invariant("a currency is a three-letter code")
        # { currency.to_s.size == 3 }`, byte for byte. Declare it before
        # the value objects that reference it — resolution happens at
        # the referencing value object's own build time, against
        # whatever sibling value objects the aggregate has already
        # built, the same ordering rule `given` carries.
        # RENAMED FROM `invariant` — item #13's full metaprogrammed
        # dispatch (slice 4b). Bootstrap-reachable, in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def invariant_impl(description, &predicate)
          return reference_named_invariant(description) unless predicate

          # moved to the language: given "a rule says what it means", on Shape.Assert

          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
        end

        private

        # PRIMITIVE 3 (RuleReference#resolve_sibling_scan) — see that
        # method's own comment for why this is a live scan, not a pool.
        def reference_named_invariant(description)
          verify_resolves_via!("invariant", "ValueObject", "sibling_scan")
          named = resolve_sibling_scan(@owner_value_objects, description, reader: :invariants) ||
                  raise(Malformed,
                        "#{@name}'s invariant #{description.inspect} names no rule a sibling value " \
                        "object on this aggregate declares — declare it once with a block, on the " \
                        "value object that needs it first, before the ones that reference it back")

          @invariants << named
        end

        public

        def build
          if @inline_closed_set_field && attributes.size > 1
            raise Malformed,
                  "#{@name}'s one_of: on :#{@inline_closed_set_field} only works when it is the " \
                  "value object's only attribute — #{attributes.size} declared here; write bare " \
                  "member lines instead for a multi-field set"
          end

          ValueObject.declare(
            name: @name, attributes: attributes,
            invariants: @invariants, members: @members,
            closed_set: @closed_set || !@members.empty?
          )
        end

        def self.build(name, owner_value_objects: [], &block)
          builder = new(name, owner_value_objects: owner_value_objects)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # THE NEW SPELLING — `attribute :name, String, one_of: %w[...]`,
        # overriding `AttributeCollector`'s own refusal (every OTHER
        # includer has no meaningful use for this). PRIVATE, like the
        # module's own version it overrides — it is a callback `attribute`
        # invokes on itself, never a word a bluebook author calls by name.
        # Refuses a SECOND attribute naming one_of: on the same value
        # object outright — a single-field set names exactly one field, by
        # construction; two would be structurally ambiguous about which
        # field each member line belongs to. `build` refuses the OTHER
        # half of that same rule (this attribute coexisting with unrelated
        # ones on a multi-field object).
        def install_inline_closed_set(field, values)
          if @inline_closed_set_field && @inline_closed_set_field != field
            raise Malformed,
                  "#{@name} declares one_of: on more than one attribute (:#{@inline_closed_set_field} " \
                  "and :#{field}) — a single-field closed set names exactly one"
          end

          @inline_closed_set_field = field
          @closed_set = true
          values.each { |value| member_impl(field => value.to_s) }
        end
      end
    end
  end
end
