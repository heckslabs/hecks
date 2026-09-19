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
    # no unambiguous mechanical phrasing, it doesn't get a sentence here
    # — a wrong sentence is worse than a missing one.
    #
    # ## Reached like any other projection
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

      # Projects `bluebook`'s declared facts as a flat list of English
      # sentences.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to render statements for
      # @param options [Hash] unused; accepted to satisfy the registry's call shape
      # @return [Array<String>] one sentence per fact, aggregate-then-entities order
      def call(bluebook:, options: {})
        holders(bluebook).flat_map { |holder| statements_for(holder) }
      end

      # Lists every fact-bearing holder in `bluebook`.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to walk
      # @return [Array<Bluebook::Aggregate, Bluebook::Entity>] every aggregate, each
      #   immediately followed by its own nested entities
      def holders(bluebook) = bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }

      # Renders every sentence for one holder.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the aggregate or entity
      #   to render sentences for
      # @return [Array<String>] `holder`'s attribute statements followed by its
      #   invariant statements
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
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the aggregate or entity
      #   whose attributes to render
      # @return [Array<String>] one sentence per list or relationship attribute; an
      #   attribute with neither yields no sentence
      def attribute_statements(holder)
        holder.attributes.filter_map { |attribute| attribute_statement(holder, attribute) }
      end

      # Renders one attribute's sentence, if it has one.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the attribute's owner,
      #   named as the sentence's subject
      # @param attribute [Bluebook::Attribute] the attribute to render
      # @return [String, nil] the attribute's sentence, or nil if it is neither a
      #   list nor a `has_one`/`belongs_to`/`reference_to` relationship
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
      # @param word [String, Symbol] the word the article precedes
      # @return [String] "An" before a leading vowel letter, "A" otherwise
      def article(word) = word.to_s.match?(/\A[AEIOUaeiou]/) ? "An" : "A"

      # Invariants live in two places — directly on the holder (an
      # aggregate-level rule, checked after every command) and on every
      # value object nested inside it — `DocsProjector#rules_of`'s own
      # `value_object_for` lookup is the precedent for walking both.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the aggregate or entity
      #   to render invariant sentences for
      # @return [Array<String>] `holder`'s own invariant sentences, followed by every
      #   nested value object's
      def invariant_statements(holder)
        own = Array(holder.respond_to?(:invariants) ? holder.invariants : [])
        nested = Array(holder.respond_to?(:value_objects) ? holder.value_objects : []).flat_map(&:invariants)
        (own + nested).map { |invariant| invariant_statement(invariant) }
      end

      # The domain author's own words, capitalized and punctuated —
      # nothing else. `invariant("a pizza is named")` already reads as
      # a sentence; this is the entire transformation.
      #
      # @param invariant [Bluebook::Invariant] the invariant to render
      # @return [String] `invariant.description`, capitalized and ending in
      #   `.`, `!`, or `?`
      def invariant_statement(invariant)
        text = invariant.description.to_s.strip
        text = "#{text[0].upcase}#{text[1..]}" if text[0]
        text.end_with?(".", "!", "?") ? text : "#{text}."
      end
    end
  end
end
