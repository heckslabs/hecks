require_relative "../projector"

module Hecks
  module Projections
    # A domain's own declared facts, projected as plain english sentences
    # — one atomic, independently-checkable statement per fact, not a
    # flowing document (`Projections::Reference`/`DocsProjector` already
    # do that job well; this is a flat list a caller can iterate, diff,
    # or hand to something else entirely — a review, a test-plan seed,
    # a sanity check that the domain still says what someone thinks it
    # says).
    #
    # ## Never invents a sentence from nothing
    #
    # `DocsProjector`'s own discipline, held here too: a relationship's
    # sentence is built mechanically from its own declared shape (holder,
    # target, relationship kind — the same facts `Projections::Diagrams`'s
    # own relationship_edge already reads), and an invariant's sentence is
    # the domain author's own `description`, capitalized and punctuated,
    # never paraphrased. If a fact has no author-written description and
    # no unambiguous mechanical phrasing, it doesn't get a sentence here —
    # a wrong sentence is worse than a missing one.
    #
    # ## Reachable like any projection
    #
    # No new facade wiring needed: `Pizzas.project(Projections::Statements)`
    # — `Facade::Surface::Chapter#project`'s own comment already settled
    # this ("anything genuinely needing the graph is a projector, and a
    # projector is given it"). `bin/statements` is a thin, optional
    # convenience for reaching the same call from a shell.
    #
    # ## MVP scope
    #
    # "has many"/"has a"/"belongs to"/"references" sentences for every
    # list or relationship attribute, and every invariant's own
    # description (aggregate-level and every nested value object's),
    # verbatim. Lifecycle transitions and command given/ensures read the
    # same way and are the natural next sentences — not built yet.
    module Statements
      extend Hecks::Projector::Target

      projects_as :statements

      module_function

      # Projects every reachable fact in the chapter into its flat sentence list.
      #
      # @param bluebook [Bluebook::Chapter] the chapter being projected
      # @param options [Hash{Symbol => Object}] ignored; present to satisfy the
      #   `Projector::Target` calling convention
      # @return [Array<String>] one sentence per attribute relationship and invariant,
      #   in holder order
      def call(bluebook:, options: {})
        holders(bluebook).flat_map { |holder| statements_for(holder) }
      end

      # Every construct that can carry its own attributes and invariants — an
      # aggregate and each of its entities.
      #
      # @param bluebook [Bluebook::Chapter] the chapter being walked
      # @return [Array<Bluebook::Aggregate, Bluebook::Entity>] every aggregate followed
      #   by its own entities, in declaration order
      def holders(bluebook) = bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }

      # All of one holder's sentences: its attribute relationships, then its invariants.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct being
      #   projected
      # @return [Array<String>] the holder's sentences
      def statements_for(holder)
        attribute_statements(holder) + invariant_statements(holder)
      end

      # "MANY" reads the same way regardless of what's behind it — a
      # `has_many` relationship to another aggregate and a plain
      # `list_of(Topping)` value-object attribute are the same idea to
      # someone reading the domain in English ("an Order has many
      # toppings" is true either way), even though they're two
      # different IR shapes (a `Reference` versus an ordinary type).
      # `attribute.name` carries the noun, not the target's own class
      # name, because the field's own name is what the domain author
      # actually chose to call the collection — "toppings", not
      # "Topping".
      # Projects every one of a holder's attributes that says something in plain
      # English — a list, or a named relationship.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct whose
      #   attributes are being read
      # @return [Array<String>] one sentence per list or relationship attribute; a
      #   plain scalar attribute contributes none
      def attribute_statements(holder)
        holder.attributes.filter_map { |attribute| attribute_statement(holder, attribute) }
      end

      # Projects one attribute's relationship, if it has one worth stating.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the attribute's owning
      #   construct, named as the sentence's subject
      # @param attribute [Bluebook::Attribute] the attribute being projected
      # @return [String, nil] the sentence, or `nil` if `attribute` is neither a list
      #   nor a `has_one`/`belongs_to`/`reference_to` relationship
      def attribute_statement(holder, attribute)
        subject = "#{article(holder.hecks_name)} #{holder.hecks_name}"
        return "#{subject} has many #{attribute.name}." if attribute.list?

        target = attribute.relationship && attribute.type.target_name
        target_phrase = target && "#{article(target).downcase} #{target}"
        case attribute.relationship
        when "has_one"      then "#{subject} has #{target_phrase}."
        when "belongs_to"   then "#{subject} belongs to #{target_phrase}."
        when "reference_to" then "#{subject} references #{target_phrase}."
        end
      end

      # "An account", not "A ACCOUNT" — every subject/object noun here is
      # a bare construct name (`ATMCard`, `ExternalTransfer`, `Account`),
      # never free text, so the ordinary "starts with a vowel LETTER"
      # heuristic is safe: this language's own naming never produces the
      # English exceptions that heuristic gets wrong (an "hour", a
      # "university") because a construct name is always spelled as a
      # plain word, never an abbreviation read letter-by-letter or a
      # word starting with a consonant letter but a vowel sound.
      #
      # @param word [String] a construct name to prefix
      # @return [String] `"An"` if `word` starts with a vowel letter, `"A"` otherwise
      def article(word) = word.to_s.match?(/\A[AEIOUaeiou]/) ? "An" : "A"

      # Invariants live in two places — directly on the holder (an
      # aggregate-level rule, checked after every command) and on every
      # value object nested inside it — `DocsProjector#rules_of`'s own
      # `value_object_for` lookup is the precedent for walking both.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct whose
      #   invariants, and whose value objects' invariants, are being read
      # @return [Array<String>] one sentence per invariant, the holder's own first,
      #   then each nested value object's
      def invariant_statements(holder)
        own = Array(holder.respond_to?(:invariants) ? holder.invariants : [])
        nested = Array(holder.respond_to?(:value_objects) ? holder.value_objects : []).flat_map(&:invariants)
        (own + nested).map { |invariant| invariant_statement(invariant) }
      end

      # The domain author's own words, capitalized and punctuated —
      # nothing else. `invariant("a pizza is named")` already reads as
      # a sentence; this is the entire transformation.
      #
      # @param invariant [Bluebook::Invariant] the invariant being projected
      # @return [String] the invariant's `description`, capitalized, ending with `.`,
      #   `!` or `?`
      def invariant_statement(invariant)
        text = invariant.description.to_s.strip
        text = "#{text[0].upcase}#{text[1..]}" if text[0]
        text.end_with?(".", "!", "?") ? text : "#{text}."
      end
    end
  end
end
