require_relative "../projector"

module Hecks
  module Projections
    # A DOMAIN'S OWN DECLARED FACTS, PROJECTED AS PLAIN ENGLISH SENTENCES
    # — one atomic, independently-checkable statement per fact, not a
    # flowing document (`Projections::Reference`/`DocsProjector` already
    # do that job well; this is a flat list a caller can iterate, diff,
    # or hand to something else entirely — a review, a test-plan seed,
    # a sanity check that the domain still says what someone thinks it
    # says).
    #
    # NEVER INVENTS A SENTENCE FROM NOTHING — `DocsProjector`'s own
    # discipline, held here too: a relationship's sentence is built
    # MECHANICALLY from its own declared shape (holder, target,
    # relationship kind — the same facts `Projections::Diagrams`'s own
    # relationship_edge already reads), and an invariant's sentence IS
    # the domain author's own `description`, capitalized and
    # punctuated, never paraphrased. If a fact has no author-written
    # description and no unambiguous mechanical phrasing, it doesn't
    # get a sentence here — a wrong sentence is worse than a missing
    # one.
    #
    # REACHABLE THE SAME WAY EVERY PROJECTION ALREADY IS, no new facade
    # wiring needed: `Pizzas.project(Projections::Statements)` —
    # `Facade::Surface::Chapter#project`'s own comment already settled
    # this ("anything genuinely needing the graph is a projector, and a
    # projector is given it"). `bin/statements` is a thin, optional
    # convenience for reaching the same call from a shell.
    #
    # MVP SCOPE: "has many"/"has a"/"belongs to"/"references" sentences
    # for every list or relationship attribute, and every invariant's
    # own description (aggregate-level and every nested value object's),
    # verbatim. Lifecycle transitions and command given/ensures read the
    # same way and are the natural next sentences — not built yet.
    module Statements
      extend Hecks::Projector::Target

      projects_as :statements

      module_function

      def call(bluebook:, options: {})
        holders(bluebook).flat_map { |holder| statements_for(holder) }
      end

      def holders(bluebook) = bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }

      def statements_for(holder)
        attribute_statements(holder) + invariant_statements(holder)
      end

      # "MANY" READS THE SAME WAY REGARDLESS OF WHAT'S BEHIND IT — a
      # `has_many` relationship to another aggregate and a plain
      # `list_of(Topping)` value-object attribute are the same idea to
      # someone reading the domain in English ("an Order has many
      # toppings" is true either way), even though they're two
      # different IR shapes (a `Reference` versus an ordinary type).
      # `attribute.name` carries the noun, not the target's own class
      # name, because the field's own name is what the domain author
      # actually chose to call the collection — "toppings", not
      # "Topping".
      def attribute_statements(holder)
        holder.attributes.filter_map { |attribute| attribute_statement(holder, attribute) }
      end

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

      # "AN ACCOUNT", NOT "A ACCOUNT" — every subject/object noun here is
      # a bare construct name (`ATMCard`, `ExternalTransfer`, `Account`),
      # never free text, so the ordinary "starts with a vowel LETTER"
      # heuristic is safe: this language's own naming never produces the
      # English exceptions that heuristic gets wrong (an "hour", a
      # "university") because a construct name is always spelled as a
      # plain word, never an abbreviation read letter-by-letter or a
      # word starting with a consonant LETTER but a vowel SOUND.
      def article(word) = word.to_s.match?(/\A[AEIOUaeiou]/) ? "An" : "A"

      # INVARIANTS LIVE IN TWO PLACES — directly on the holder (an
      # aggregate-level rule, checked after every command) and on every
      # value object nested inside it — `DocsProjector#rules_of`'s own
      # `value_object_for` lookup is the precedent for walking both.
      def invariant_statements(holder)
        own = Array(holder.respond_to?(:invariants) ? holder.invariants : [])
        nested = Array(holder.respond_to?(:value_objects) ? holder.value_objects : []).flat_map(&:invariants)
        (own + nested).map { |invariant| invariant_statement(invariant) }
      end

      # THE DOMAIN AUTHOR'S OWN WORDS, CAPITALIZED AND PUNCTUATED —
      # nothing else. `invariant("a pizza is named")` already reads as
      # a sentence; this is the entire transformation.
      def invariant_statement(invariant)
        text = invariant.description.to_s.strip
        text = "#{text[0].upcase}#{text[1..]}" if text[0]
        text.end_with?(".", "!", "?") ? text : "#{text}."
      end
    end
  end
end
