module Hecks
  module EventStorm
    # Hecks::EventStorm::Result
    #
    # Return value from Hecks.from_event_storm. Contains the built Domain object,
    # the generated DSL string, and any warnings produced during parsing.
    #
    #   result = Hecks.from_event_storm("storm.md")
    #   result.domain    # => DomainModel::Structure::Domain
    #   result.dsl       # => "Hecks.domain \"Ordering\" do ..."
    #   result.warnings  # => ["Event 'Order Placed' doesn't match ..."]
    #
    class Result
      # @return [DomainModel::Structure::Domain] the built domain object
      attr_reader :domain

      # @return [String] the generated Hecks DSL source code
      attr_reader :dsl

      # @return [Array<String>] warnings from parsing and validation
      attr_reader :warnings

      # Initializes a Result with the domain, DSL, and warnings.
      #
      # @param domain [DomainModel::Structure::Domain] the built domain object
      # @param dsl [String] the generated Hecks DSL source code
      # @param warnings [Array<String>] any warnings from parsing/validation
      def initialize(domain:, dsl:, warnings: [])
        @domain = domain
        @dsl = dsl
        @warnings = warnings
      end
    end
  end
end
