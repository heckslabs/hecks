require_relative "../projector"
require_relative "statements/relationships"
require_relative "statements/actions"

module Hecks
  module Projections
    # A domain's declared facts as flat plain-English sentences, one checkable statement per fact:
    # what each thing holds and points at, what is always true of it, how it moves between
    # states, and what each of its commands checks. Never invents one: relationships read from
    # shape and names, and every rule uses the author's own description.
    #
    #   Pizzas.project(Projections::Statements) # => ["Each order holds a list of toppings.", ...]
    module Statements
      extend Hecks::Projector::Target

      projects_as :statements

      module_function

      # Projects every reachable fact in the chapter into its flat sentence list.
      #
      # @param bluebook [Bluebook::Chapter] the chapter being projected
      # @param options [Hash{Symbol => Object}] ignored; present to satisfy the
      #   `Projector::Target` calling convention
      # @return [Array<String>] each holder's relationships, invariants, moves and command
      #   rules, in holder order
      def call(bluebook:, options: {})
        holders(bluebook).flat_map { |holder| statements_for(holder) }
      end

      def holders(bluebook) = bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }

      def statements_for(holder)
        attribute_statements(holder) + invariant_statements(holder) +
          Actions.lifecycle(holder) + Actions.rules(holder)
      end

      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct being read
      # @return [Array<String>] one sentence per list or reference attribute
      def attribute_statements(holder)
        holder.attributes.filter_map { |attribute| attribute_statement(holder, attribute) }
      end

      # @return [String, nil] the attribute's sentence, or nil for a plain field
      def attribute_statement(holder, attribute) = Relationships.sentence(holder, attribute)

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
