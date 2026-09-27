require_relative "../projector"

module Hecks
  module Projections
    # A domain's declared facts as flat plain-English sentences, one checkable statement per fact.
    # Never invents one: relationships read from shape, invariants use the author's description.
    #
    #   Pizzas.project(Projections::Statements) # => ["A Pizza has many toppings.", ...]
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

      def holders(bluebook) = bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }

      def statements_for(holder)
        attribute_statements(holder) + invariant_statements(holder)
      end

      # `has_many` and `list_of` read the same in English; `attribute.name` is the author's noun.
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

      # Vowel-letter heuristic is safe: construct names are plain words, never initialisms.
      # @param word [String] a construct name to prefix
      # @return [String] `"An"` if `word` starts with a vowel letter, `"A"` otherwise
      def article(word) = word.to_s.match?(/\A[AEIOUaeiou]/) ? "An" : "A"

      # Invariants sit on the holder and on each nested value object; both are read.
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct whose
      #   invariants, and whose value objects' invariants, are being read
      # @return [Array<String>] one sentence per invariant, the holder's own first,
      #   then each nested value object's
      def invariant_statements(holder)
        own = Array(holder.respond_to?(:invariants) ? holder.invariants : [])
        nested = Array(holder.respond_to?(:value_objects) ? holder.value_objects : []).flat_map(&:invariants)
        (own + nested).map { |invariant| invariant_statement(invariant) }
      end

      # The author's own description, capitalized and punctuated; no other transformation.
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
