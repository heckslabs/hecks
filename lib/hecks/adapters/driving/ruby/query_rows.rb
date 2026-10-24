module Hecks
  module Adapters
    module Driving
      module Ruby
        # What an aggregate module's query method answers: the rows, as an Array, that also
        # remember the query and the arguments they were asked with, so a bulk run handed them
        # (`over:`) runs that query itself rather than a list read earlier (ADR 0121).
        class QueryRows < Array
          # @return [String] the query's verb, `"Domain::Aggregate.Query"`
          attr_reader :verb

          # @return [Hash{Symbol => Object}] the arguments the query was asked with
          attr_reader :arguments

          # @param rows [Array<Hash>] the rows the query answered
          # @param verb [String] the query's verb
          # @param arguments [Hash{Symbol => Object}] the arguments it was asked with
          def initialize(rows, verb:, arguments:)
            super(rows)
            @verb      = verb
            @arguments = arguments
          end
        end
      end
    end
  end
end
