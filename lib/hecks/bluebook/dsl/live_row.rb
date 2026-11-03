module Hecks
  module Bluebook
    module DSL
      # The liveness rule for a grammar keyword row, shared by `WordGate` and `GenericDispatch`.
      #
      # A row is live when its status is admitted, deprecated, or unset. Rust's `KeywordRow::live`
      # in `rust/parser/src/keywords.rs` reads the same set, so a retired or proposed row is
      # neither admitted by its word or its `was` alias, nor dispatched, on either parser.
      module LiveRow
        STATUSES = ["", "admitted", "deprecated"].freeze

        module_function

        # Whether a keyword row takes part in admission and dispatch.
        #
        # @param row [Hash] a grammar keyword row read from `MetaValidator::SyntaxBoot`
        # @return [Boolean]
        def live?(row)
          STATUSES.include?(row[:status].to_s)
        end
      end
    end
  end
end
