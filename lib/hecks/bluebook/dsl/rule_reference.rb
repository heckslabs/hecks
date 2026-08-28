module Hecks
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
      # shape would be a real behavior change (see `#lookup`, below, for
      # which construct uses which), not the pure internal refactor this
      # module is. `build_rule` is the one piece that WAS genuinely
      # identical across all 7 declaring methods (`given`×3,
      # `invariant`×3, `ensures`×1) before this file existed — extract
      # predicate source, refuse if extraction failed, build the struct.
      #
      # `#lookup`/`#verify_resolves_via!` read WHICH construct uses which
      # primitive off the self-hosted grammar table itself
      # (`Keyword#resolves_via`, `syntax.bluebook`) — not a Ruby-only
      # Hash cross-checked afterward (this file's OWN earlier shape, one
      # round ago) — so a real domain's own boot, not just `bundle exec
      # rspec`, fails loudly the moment the table and this file's own
      # hand-written resolution methods disagree.
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
        # (docs/implemented/resolution-rules/chapter-given.md). Returns the full
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

        # WHICH CONSTRUCT USES WHICH PRIMITIVE — no longer a Ruby-only
        # Hash (that WAS this constant's own shape, one round ago): the
        # user's own correction — "my goal is that if they read the same
        # table they behave identically" — means a table only Ruby ever
        # reads cannot deliver that, no matter how faithfully it is
        # cross-checked afterward. `Keyword#resolves_via`/`#disambiguator`
        # (self-hosted, `syntax.bluebook`) is the REAL table now — the
        # SAME generated data `rust/parser/src/keywords.rs` is generated
        # from (`bin/project_parser_table`). `#lookup` reads it live.
        #
        # THE ONE UNAVOIDABLE EXCEPTION: the meta-domain's own bootstrap
        # (`MetaValidator.load_grammar_into`) dispatches `given`/
        # `invariant` on ITSELF 61 times while building the very grammar
        # table that would answer "how does given/Aggregate resolve" —
        # `MetaValidator.grammar_registry`/`SyntaxBoot.call` are not
        # ready yet, and cannot be made ready without ALREADY having
        # resolved a `given` somewhere upstream. `MetaValidator.
        # bootstrapping?` is the SAME guard `MetaValidator.call` (the
        # judge) already uses to skip self-judging during this exact
        # window — `#lookup` uses it too, falling back to
        # `BOOTSTRAP_FALLBACK` (below) ONLY while it's true. Every REAL
        # domain (banking, pizzas, compliance, any future one) boots
        # AFTER `grammar_registry` is fully built and memoized, so reads
        # the real table, every time, no exception.
        BOOTSTRAP_FALLBACK = {
          %w[given Aggregate]       => { resolves_via: "owner_keyed", disambiguator: "declared_by" },
          %w[given Entity]          => { resolves_via: "owner_keyed", disambiguator: "declared_by" },
          %w[given Command]         => { resolves_via: "hash_chain" },
          %w[invariant ValueObject] => { resolves_via: "sibling_scan" }
        }.freeze

        def lookup(word, context)
          if MetaValidator.bootstrapping?
            BOOTSTRAP_FALLBACK[[word, context]] || {}
          else
            row = MetaValidator::SyntaxBoot.call[:keywords]
                                           .find { |r| r[:word] == word && r[:context] == context }
            return {} unless row

            { resolves_via: row[:resolves_via], disambiguator: row[:disambiguator] }
              .transform_values { |value| value.to_s.empty? ? nil : value }
          end
        end

        # A LIVE CROSS-CHECK, not a spec-only one — every REAL domain's
        # own boot (not just `bundle exec rspec`) now genuinely fails
        # loudly if a construct's own hand-written resolution method
        # ever disagrees with what the self-hosted grammar table claims
        # for it. Each of the three `reference_named_*` methods below
        # calls this FIRST, naming the primitive it is ABOUT to use —
        # if `syntax.bluebook`'s own `resolves_via` for this exact
        # (word, context) pair ever names something else, this is a
        # real drift between the language's own self-description and
        # its own implementation, caught at the next boot of ANYTHING,
        # not just the next `rspec` run.
        def verify_resolves_via!(word, context, expected_primitive)
          actual = lookup(word, context)[:resolves_via]
          return if actual == expected_primitive

          raise "internal: syntax.bluebook says #{word}/#{context} resolves via " \
                "#{actual.inspect}, but #{word}'s own Ruby builder is about to use " \
                "#{expected_primitive.inspect} — the grammar table and the " \
                "implementation have drifted"
        end
      end
    end
  end
end
