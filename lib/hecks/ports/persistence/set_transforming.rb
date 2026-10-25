require_relative "set_statement"

module Hecks
  module Ports
    module Persistence
      # The repository's door to its adapter's one-statement rewrite (ADR 0128). Mixed into
      # `AppendOnly`, which supplies `@adapter`.
      module SetTransforming
        # Whether the adapter answers a {SetStatement} with one statement. The declared
        # `provides "set_transform"` says a store should; this says this adapter does.
        #
        # @return [Boolean]
        def set_transform? = @adapter.respond_to?(:apply_set_transform) && @adapter.respond_to?(:set_transform_dialect)

        # @return [String, nil] the dialect the adapter's statement is written in, such as
        #   `"sqlite"`; nil when it answers no statement
        def set_transform_dialect = (@adapter.set_transform_dialect if set_transform?)

        # Rewrites every row a statement selects, in one statement, and journals each.
        #
        # @param statement [SetStatement] the command over the query
        # @return [Array<Runtime::Instance>] the rows it updated, as they now stand
        # @raise [Adapters::SetTransform::Uncompilable] before anything is written, when part of
        #   the statement has no form in the adapter's dialect
        # @raise [Adapters::SetTransform::Declined] if the store refused the statement
        def apply_set_transform(statement) = @adapter.apply_set_transform(statement)
      end
    end
  end
end
