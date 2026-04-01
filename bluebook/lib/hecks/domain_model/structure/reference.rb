module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::Reference
    #
    # Represents a relationship from one aggregate to another. References are
    # first-class domain concepts — the domain layer holds live objects in memory,
    # never foreign key IDs. Persistence is the only layer that knows about IDs.
    #
    # The +kind+ is set post-build by DomainBuilder#classify_references:
    #   :composition    — target is a VO/entity within the same aggregate
    #   :aggregation    — target is another aggregate root
    #   :cross_context  — target is in a different bounded context
    #
    #   ref = Reference.new(name: :team, type: "Team")
    #   ref = Reference.new(name: :home_team, type: "Team", role: "home_team")
    #
    class Reference
      # @return [Symbol] the role name (e.g., :team, :home_team)
      attr_reader :name

      # @return [String] the target aggregate type name (e.g., "Team")
      attr_reader :type

      # @return [String, nil] the domain name for cross-context references
      attr_reader :domain

      # @return [Symbol, nil] the relationship kind, set by classify_references
      attr_accessor :kind

      # @return [Symbol, Boolean] validation mode — true/:exists checks existence,
      #   false skips validation entirely (opt-out for eventual consistency)
      attr_reader :validate

      def initialize(name:, type:, domain: nil, kind: nil, validate: true)
        @name = name.to_sym
        @type = type.to_s
        @domain = domain
        @kind = kind
        @validate = validate
      end

      # Returns true if this is a cross-context reference.
      def cross_context?
        kind == :cross_context
      end
    end
    end
  end
end
