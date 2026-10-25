require_relative "../grammar"

module Hecks
  module Bulk
    # The checks that say whether a bulk run's command and aggregate can be one statement
    # (ADR 0128): what the statement cannot check per row rules a run out, and every expression
    # must compile for the store's dialect. Mixed into {SetPlanner}, which supplies `@command`,
    # `@aggregate`, `@repository` and the run's names.
    module SetEligibility
      # The mutations a statement writes.
      COMPILED_OPS = %i[set increment decrement].freeze

      private

      def eligible?
        store_compiles? && command_compiles? && aggregate_compiles? && expressions_compile?
      end

      def store_compiles?
        @registry.adapter_provides?(@domain, @aggregate, "set_transform") && @repository.set_transform?
      end

      # A command acting on one existing record of its own aggregate, every argument of which has
      # a value without the caller, and nothing checked after its writes.
      def command_compiles?
        acts_on_own_record? && [@command.needs, @command.ensures].all?(&:empty?) &&
          @command.mutations.all? { |mutation| COMPILED_OPS.include?(mutation.op) } &&
          @command.attributes.all? { |attribute| self_supplied?(attribute) }
      end

      def acts_on_own_record? = @command.references.to_s == @aggregate.hecks_name && !@command.creates?

      # An argument the run never passes must have a default, or be one the command can lack.
      def self_supplied?(attribute) = !attribute.reference? && (attribute.optional? || !attribute.default.nil?)

      # No rule the store would have to check against other records or the settled whole.
      def aggregate_compiles?
        [@aggregate.invariants, @aggregate.entities, @aggregate.projected_fields].all?(&:empty?) &&
          @aggregate.attributes.none?(&:reference?) && @aggregate.queries.none?(&:authorization)
      end

      def expressions_compile?
        dialect = @repository.set_transform_dialect
        texts = @command.givens.map(&:canonical) +
                @command.mutations.filter_map { |mutation| mutation.source.text if mutation.source.is_a?(Computed) }
        texts.all? { |text| Grammar.compiles_for?(text, dialect) }
      end
    end
  end
end
