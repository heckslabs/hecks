require_relative "bootstrap_table"

module Hecks
  module Bluebook
    module DSL
      # The three "declared once, referenced by name" resolution primitives shared by
      # every given/invariant/ensures scope in this DSL (ADR 0025).
      module RuleReference
        # Raised when the syntax table names a resolution this module cannot perform.
        class Error < RuntimeError; end

        module_function

        # Extracts a predicate's source and builds the rule struct (Given or Invariant),
        # refusing when the source could not be read.
        #
        # extraction_failure is required, not hardcoded, since given/invariant/ensures
        # each need their own exact refusal wording.
        #
        # @param struct_class [Class] the rule struct to build (Given or Invariant)
        # @param description [String] the rule's description
        # @param predicate [Proc] the rule's predicate block
        # @param context [Hash] `owner_name:`, `word:` and `extraction_failure:`, all required
        # @return [Object] an instance of `struct_class`
        # @raise [Bluebook::DSL::Malformed] if the predicate's source could not be read
        def build_rule(struct_class, description, predicate, **context)
          owner_name, word, extraction_failure = context.fetch_values(:owner_name, :word, :extraction_failure)
          canonical = Ports::Extraction.canonical(predicate)

          if canonical.to_s.empty?
            raise Malformed,
                  "#{owner_name}'s #{word} #{description.inspect} did not survive " \
                  "extraction — #{extraction_failure}"
          end

          ast = checked_ast(canonical, owner_name, "#{word} #{description.inspect}")
          struct_class.new(description: description, canonical: canonical, predicate: predicate, ast: ast)
        end

        # Emits a predicate's AST and refuses the patterns and lookups the IR cannot share.
        def checked_ast(canonical, owner_name, rule_word)
          ast = Expression::AstJson.emit_predicate(canonical)
          Expression::AstJson.refuse_unshared_patterns!(ast, owner: owner_name, word: rule_word)
          Expression::AstJson.refuse_unresolvable_lookups!(ast, owner: owner_name, word: rule_word)
          ast
        end

        # Resolution primitive 1: first pool (in order) whose hash has this description wins.
        def resolve_hash_chain(pools, description)
          pools.each { |pool| return pool[description] if pool.key?(description) }
          nil
        end

        # Resolution primitive 2: one pool keyed by declaring owner. Returns every candidate
        # rather than raising, so each caller keeps its own "none"/"ambiguous"/"wrong owner"
        # wording.
        def resolve_owner_keyed(pool, description)
          pool[description] || {}
        end

        # Resolution primitive 3: scans already-built siblings' own rule collections directly
        # instead of a separately-maintained pool, since declaration order guarantees every
        # sibling exists by the time a later one references it.
        def resolve_sibling_scan(siblings, description, reader:)
          siblings.flat_map { |sibling| sibling.public_send(reader) }
                  .find { |rule| rule.description == description }
        end

        # Which (word, context) pair resolves via which primitive, read from the self-hosted
        # grammar table (Keyword#resolves_via in syntax.bluebook) once it exists.
        #
        # Projected ahead of time into bootstrap_table.rb for the bootstrap window before
        # the grammar table itself is built (MetaValidator.bootstrapping?); kept in sync by
        # hecks project_bootstrap_table, pinned by spec/bootstrap_table_spec.rb.
        BOOTSTRAP_FALLBACK = BootstrapTable::RESOLVES

        # Reads how a (word, context) pair resolves rule references, off the self-hosted
        # grammar table (or, during bootstrap, the projected fallback).
        def lookup(word, context)
          return BOOTSTRAP_FALLBACK[[word, context]] || {} if MetaValidator.bootstrapping?

          row = MetaValidator::SyntaxBoot.call[:keywords]
                                         .find { |r| r[:word] == word && r[:context] == context }
          row ? resolution_of(row) : {}
        end

        # The primitive and disambiguator a grammar-table row names, blank values as nil.
        def resolution_of(row)
          { resolves_via: row[:resolves_via], disambiguator: row[:disambiguator] }
            .transform_values { |value| value.to_s.empty? ? nil : value }
        end

        # Raises if syntax.bluebook's own resolves_via for (word, context) disagrees with
        # the primitive the caller is about to use — catches drift between the grammar
        # table and its Ruby implementation at boot, not just in spec.
        def verify_resolves_via!(word, context, expected_primitive)
          actual = lookup(word, context)[:resolves_via]
          return if actual == expected_primitive

          raise Error, "internal: syntax.bluebook says #{word}/#{context} resolves via " \
                       "#{actual.inspect}, but #{word}'s own Ruby builder is about to use " \
                       "#{expected_primitive.inspect} — the grammar table and the " \
                       "implementation have drifted"
        end
      end
    end
  end
end
