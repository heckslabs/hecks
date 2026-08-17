module Hecksagain
  module Bluebook
    module DSL
      # THE THREE RESOLUTION PRIMITIVES the S10 given/invariant family's
      # own "declared once, referenced by name" mechanism (ADR 0025)
      # reduces to, at every scope this language has grown one so far
      # (a command referencing its owner or a sibling piece's entity-wide
      # pool; an aggregate referencing another aggregate chapter-wide; a
      # value object referencing a sibling value object on the same
      # aggregate) — extracted here, once, so the NEXT scope this family
      # widens to (there will be one — see docs/resolution-rules/
      # chapter-given.md's own "Known limitations" for two already named)
      # reuses one of these three shapes instead of a fourth hand-written
      # near-duplicate resolver.
      #
      # NOT ONE UNIFIED ALGORITHM — a real design question this file
      # answers directly: the THREE existing resolvers are not
      # superficially different, they are STRUCTURALLY different (a
      # multi-pool fallback CHAIN; ONE pool keyed by declaring OWNER,
      # needing disambiguation; a LIVE SCAN over already-built sibling
      # objects with no separate pool at all) — forcing them into one
      # shape would be a real behavior change (see RESOLUTION_RULES,
      # below, for which construct uses which), not the pure internal
      # refactor this module is. `build_rule` is the one piece that WAS
      # genuinely identical across all 7 declaring methods (`given`×3,
      # `invariant`×3, `ensures`×1) before this file existed — extract
      # predicate source, refuse if extraction failed, build the struct.
      #
      # spec/rule_reference_spec.rb cross-checks RESOLUTION_RULES against
      # what each builder's own method actually calls, the same
      # generator-and-gate-read-one-source discipline
      # `Assembly::Contracts` already holds itself to on the read side.
      module RuleReference
        module_function

        # `struct_class` is `Given` or `Invariant` (both `Struct.new(
        # :description, :canonical, :predicate, keyword_init: true)` —
        # `Given` lives in command.rb, `Invariant` in value_object.rb).
        # `owner_name`/`word` are ONLY for the refusal message's own
        # wording. `extraction_failure` is the tail of that same
        # message, and stays a REQUIRED parameter rather than one
        # hardcoded string on purpose — `given` ("its source could not
        # be read, so no other runtime could ever evaluate it"),
        # `invariant` ("it would be a rule the IR cannot carry"), and
        # `ensures` ("a postcondition is carried as text, and this one
        # has none") each already had their OWN exact wording before
        # this method existed; unifying them into one generic sentence
        # would be a real (if small) behavior change this refactor is
        # not making.
        def build_rule(struct_class, description, predicate, owner_name:, word:, extraction_failure:)
          canonical = Ports::Extraction.canonical(predicate)

          if canonical.to_s.empty?
            raise Malformed,
                  "#{owner_name}'s #{word} #{description.inspect} did not survive " \
                  "extraction — #{extraction_failure}"
          end

          struct_class.new(description: description, canonical: canonical, predicate: predicate)
        end

        # PRIMITIVE 1 — an ORDERED CHAIN of flat `Hash[description] =>
        # Rule` pools, first match wins. `CommandBuilder#given`'s own
        # two-pool shape (its OWN owner's `named_givens`, then a sibling
        # piece's entity-wide pool) is this with a 2-element chain — a
        # future single-pool bare reference is the same primitive with a
        # 1-element chain, not a separate "just look in one hash" method.
        def resolve_hash_chain(pools, description)
          pools.each { |pool| return pool[description] if pool.key?(description) }
          nil
        end

        # PRIMITIVE 2 — ONE pool keyed BY DECLARING OWNER,
        # `Hash[description][owner] => Rule` — `AggregateBuilder#given`'s
        # own chapter-wide shape, the only construct so far where the
        # SAME description can mean two genuinely different predicates
        # (docs/resolution-rules/chapter-given.md). Returns the full
        # candidates Hash (0, 1, or many entries) — deliberately NOT
        # raising here, so each caller keeps its own exact refusal
        # wording for "none," "ambiguous," and "declared_by: named the
        # wrong owner" rather than one generic message papering over all
        # three.
        def resolve_owner_keyed(pool, description)
          pool[description] || {}
        end

        # PRIMITIVE 3 — a LIVE SCAN over already-built SIBLING OBJECTS'
        # own collections, not a separately-maintained pool at all —
        # `ValueObjectBuilder#invariant`'s own shape: every sibling value
        # object on the same aggregate has ALREADY been built by the time
        # a later one references back (declaration order, the same
        # constraint every scope in this family carries), so there is
        # nothing to write through — just read their own already-declared
        # rules directly. `reader` is the method name to call on each
        # sibling (`:invariants` today; kept a parameter, not hardcoded,
        # since a future sibling-scan scope might reference a different
        # collection).
        def resolve_sibling_scan(siblings, description, reader:)
          siblings.flat_map { |sibling| sibling.public_send(reader) }
                  .find { |rule| rule.description == description }
        end

        # WHICH CONSTRUCT USES WHICH PRIMITIVE — documentation AND a real
        # cross-checked table (spec/rule_reference_spec.rb), not just a
        # comment. `pools`/`pool`/`siblings` name the INSTANCE VARIABLE(s)
        # the primitive is called against, for the spec's own reflection
        # to verify against; they are not read live by anything at
        # runtime — each builder's own method still calls the primitive
        # directly, with its own local `@ivar`s, exactly the way any
        # other Ruby method call to a shared module method works.
        RESOLUTION_RULES = {
          "Command"     => { kind: "given", primitive: :hash_chain,
                              pools: %i[@named_givens @entity_shared_givens] },
          "Aggregate"   => { kind: "given", primitive: :owner_keyed,
                              pool: :@chapter_named_givens, disambiguator: :declared_by },
          "ValueObject" => { kind: "invariant", primitive: :sibling_scan,
                              siblings: :@owner_value_objects, reader: :invariants }
        }.freeze
      end
    end
  end
end
