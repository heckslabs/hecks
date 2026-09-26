require_relative "bootstrap_table"

module Hecks
  module Bluebook
    module DSL
      # The three resolution primitives the S10 given/invariant family's
      # own "declared once, referenced by name" mechanism (ADR 0025)
      # reduces to, at every scope this language has grown one so far
      # (a command referencing its owner or a sibling piece's entity-wide
      # pool; an aggregate referencing another aggregate chapter-wide; a
      # value object referencing a sibling value object on the same
      # aggregate) — extracted here, once, so the next scope this family
      # widens to (there will be one — see docs/resolution-rules/
      # chapter-given.md's own "Known limitations" for two already named)
      # reuses one of these three shapes instead of a fourth hand-written
      # near-duplicate resolver.
      #
      # ## Not one unified algorithm
      #
      # A real design question this file answers directly: the three existing
      # resolvers are not superficially different, they are structurally different (a
      # multi-pool fallback chain; one pool keyed by declaring owner,
      # needing disambiguation; a live scan over already-built sibling
      # objects with no separate pool at all) — forcing them into one
      # shape would be a real behavior change (see `#lookup`, below, for
      # which construct uses which), not the pure internal refactor this
      # module is. `build_rule` is the one piece that was genuinely
      # identical across all 7 declaring methods (`given`×3,
      # `invariant`×3, `ensures`×1) before this file existed — extract
      # predicate source, refuse if extraction failed, build the struct.
      #
      # ## Resolution rules read off the grammar table, not a Ruby-only mirror
      #
      # `#lookup`/`#verify_resolves_via!` read which construct uses which
      # primitive off the self-hosted grammar table itself
      # (`Keyword#resolves_via`, `syntax.bluebook`), so a real domain's own boot, not just
      # `bundle exec rspec`, fails loudly the moment the table and this file's own
      # hand-written resolution methods disagree.
      module RuleReference
        module_function

        # Extracts a predicate block's source and builds the rule struct that holds it,
        # refusing when the source could not be read.
        #
        # `struct_class` is `Given` or `Invariant` (both `Struct.new(
        # :description, :canonical, :predicate, :ast, keyword_init: true)` —
        # `Given` lives in command.rb, `Invariant` in value_object.rb).
        # `owner_name`/`word` are only for the refusal message's own
        # wording. `extraction_failure` is the tail of that same
        # message, and stays a required parameter rather than one
        # hardcoded string on purpose — `given` ("its source could not
        # be read, so no other runtime could ever evaluate it"),
        # `invariant` ("it would be a rule the IR cannot carry"), and
        # `ensures` ("a postcondition is carried as text, and this one
        # has none") each already had their own exact wording before
        # this method existed; unifying them into one generic sentence
        # would be a real (if small) behavior change this refactor is
        # not making.
        #
        # @param struct_class [Class] the rule struct to build — `Bluebook::Given` or
        #   `Bluebook::Invariant`
        # @param description [String] the rule's own description, as declared by the caller's
        #   own `given`/`invariant`/`ensures` word
        # @param predicate [Proc] the rule's own body block, never called here — only its
        #   extracted source is used
        # @param owner_name [String] the declaring construct's own name, for the refusal message
        # @param word [String] the declaring word (`"given"`, `"invariant"`, or `"ensures"`),
        #   for the refusal message
        # @param extraction_failure [String] the refusal message's own tail, naming what an
        #   unreadable predicate would mean for this particular word
        # @return [Bluebook::Given, Bluebook::Invariant] the built rule struct, an instance of
        #   `struct_class`
        # @raise [Bluebook::DSL::Malformed] if `predicate`'s source could not be extracted, or
        #   it matches against a pattern construct `Expression::AstJson::PatternSubset` refuses, or
        #   it calls a method the expression language does not have
        def build_rule(struct_class, description, predicate, owner_name:, word:, extraction_failure:)
          canonical = Ports::Extraction.canonical(predicate)

          if canonical.to_s.empty?
            raise Malformed,
                  "#{owner_name}'s #{word} #{description.inspect} did not survive " \
                  "extraction — #{extraction_failure}"
          end

          rule_word = "#{word} #{description.inspect}"
          ast = Expression::AstJson.emit_predicate(canonical)
          Expression::AstJson.refuse_unshared_patterns!(ast, owner: owner_name, word: rule_word)
          Expression::AstJson.refuse_unresolvable_lookups!(ast, owner: owner_name, word: rule_word)
          struct_class.new(description: description, canonical: canonical, predicate: predicate, ast: ast)
        end

        # Primitive 1 — an ordered chain of flat `Hash[description] =>
        # Rule` pools, first match wins. `CommandBuilder#given`'s own
        # two-pool shape (its own owner's `named_givens`, then a sibling
        # piece's entity-wide pool) is this with a 2-element chain — a
        # future single-pool bare reference is the same primitive with a
        # 1-element chain, not a separate "just look in one hash" method.
        # @param pools [Array<Hash{String => Bluebook::Given, Bluebook::Invariant}>] pools to
        #   search in order; the first pool holding `description` wins
        # @param description [String] the rule's own description to find
        # @return [Bluebook::Given, Bluebook::Invariant, nil] the matching rule, or `nil` if no
        #   pool has one
        def resolve_hash_chain(pools, description)
          pools.each { |pool| return pool[description] if pool.key?(description) }
          nil
        end

        # Primitive 2 — one pool keyed by declaring owner,
        # `Hash[description][owner] => Rule` — `AggregateBuilder#given`'s
        # own chapter-wide shape, the only construct so far where the
        # same description can mean two genuinely different predicates
        # (docs/implemented/resolution-rules/chapter-given.md). Returns the full
        # candidates Hash (0, 1, or many entries) — deliberately not
        # raising here, so each caller keeps its own exact refusal
        # wording for "none," "ambiguous," and "declared_by: named the
        # wrong owner" rather than one generic message papering over all
        # three.
        # @param pool [Hash{String => Hash{String => Bluebook::Given, Bluebook::Invariant}}]
        #   descriptions mapped to their own candidates, each keyed by declaring owner
        # @param description [String] the rule's own description to find
        # @return [Hash{String => Bluebook::Given, Bluebook::Invariant}] the candidates for
        #   `description`, keyed by declaring owner; empty when none exist
        def resolve_owner_keyed(pool, description)
          pool[description] || {}
        end

        # Primitive 3 — a live scan over already-built sibling objects'
        # own collections, not a separately-maintained pool at all —
        # `ValueObjectBuilder#invariant`'s own shape: every sibling value
        # object on the same aggregate has already been built by the time
        # a later one references back (declaration order, the same
        # constraint every scope in this family carries), so there is
        # nothing to write through — just read their own already-declared
        # rules directly. `reader` is the method name to call on each
        # sibling (`:invariants` today; kept a parameter, not hardcoded,
        # since a future sibling-scan scope might reference a different
        # collection).
        # @param siblings [Array<Object>] the already-built sibling objects to scan; each must
        #   respond to `reader`
        # @param description [String] the rule's own description to find
        # @param reader [Symbol] the method to call on each sibling to read its own rule
        #   collection, such as `:invariants`
        # @return [Bluebook::Given, Bluebook::Invariant, nil] the matching rule, or `nil` if no
        #   sibling declares one
        def resolve_sibling_scan(siblings, description, reader:)
          siblings.flat_map { |sibling| sibling.public_send(reader) }
                  .find { |rule| rule.description == description }
        end

        # **Which construct uses which primitive** — no longer a Ruby-only
        # Hash (that was this constant's own shape, one round ago): the
        # user's own correction — "my goal is that if they read the same
        # table they behave identically" — means a table only Ruby ever
        # reads cannot deliver that, no matter how faithfully it is
        # cross-checked afterward. `Keyword#resolves_via`/`#disambiguator`
        # (self-hosted, `syntax.bluebook`) is the real table now — the
        # same generated data `rust/parser/src/keywords.rs` is generated
        # from (`bin/project_parser_table`). `#lookup` reads it live.
        #
        # **The one unavoidable exception**: the meta-domain's own bootstrap
        # (`MetaValidator.load_grammar_into`) dispatches `given`/
        # `invariant` on itself 61 times while building the very grammar
        # table that would answer "how does given/Aggregate resolve" —
        # `MetaValidator.grammar_registry`/`SyntaxBoot.call` are not
        # ready yet, and cannot be made ready without already having
        # resolved a `given` somewhere upstream. `MetaValidator.
        # bootstrapping?` is the same guard `MetaValidator.call` (the
        # judge) already uses to skip self-judging during this exact
        # window — `#lookup` uses it too, falling back to
        # `BOOTSTRAP_FALLBACK` (below) only while it's true. Every real
        # domain (banking, pizzas, compliance, any future one) boots
        # after `grammar_registry` is fully built and memoized, so reads
        # the real table, every time, no exception.
        #
        # No longer kept in sync by hand — the same `resolves_via`/
        # `disambiguator` columns, projected ahead of time into the
        # committed lib/hecks/bluebook/dsl/bootstrap_table.rb
        # (bin/project_bootstrap_table, pinned by spec/bootstrap_table_spec.rb).
        BOOTSTRAP_FALLBACK = BootstrapTable::RESOLVES

        # Reads how a (word, context) pair resolves its rule references, off the self-hosted
        # grammar table itself (or, while that table is still booting, the projected fallback).
        #
        # @param word [String] the DSL word, such as `"given"` or `"invariant"`
        # @param context [String] the grammar context, such as `"Aggregate"`
        # @return [Hash{Symbol => String, nil}] `:resolves_via` and `:disambiguator` for this
        #   (word, context) pair, `nil`-valued when the row leaves either blank, or `{}` if no row
        #   matches at all
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

        # A live cross-check, not a spec-only one — every real domain's
        # own boot (not just `bundle exec rspec`) now genuinely fails
        # loudly if a construct's own hand-written resolution method
        # ever disagrees with what the self-hosted grammar table claims
        # for it. Each of the three `reference_named_*` methods below
        # calls this first, naming the primitive it is about to use —
        # if `syntax.bluebook`'s own `resolves_via` for this exact
        # (word, context) pair ever names something else, this is a
        # real drift between the language's own self-description and
        # its own implementation, caught at the next boot of anything,
        # not just the next `rspec` run.
        # @param word [String] the DSL word, such as `"given"` or `"invariant"`
        # @param context [String] the grammar context, such as `"Aggregate"`
        # @param expected_primitive [String] the resolution primitive's own name the caller is
        #   about to use, such as `"hash_chain"`, `"owner_keyed"`, or `"sibling_scan"`
        # @return [void]
        # @raise [RuntimeError] if `syntax.bluebook`'s own `resolves_via` for this (word, context)
        #   pair names something other than `expected_primitive`
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
