module Hecks
  module BluebookModel
    module Structure

    # Hecks::BluebookModel::Structure::Reference
    #
    # Represents a relationship from one aggregate to another. References are
    # first-class domain concepts — the domain layer holds live objects in memory,
    # never foreign key IDs. Persistence is the only layer that knows about IDs.
    #
    # The +kind+ is set post-build by BluebookBuilder#classify_references:
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

      # @return [Symbol, Boolean] validation mode — :exists (default) checks existence,
      #   true also checks authorization, false skips all (eventual consistency)
      attr_reader :validate

      # @return [Hash{Symbol => Integer, nil}] cardinality bounds for the reference :
      #   { min: Integer, max: Integer | nil }
      #   - reference_to / has_one / belongs_to default to { min: 0, max: 1 }
      #   - has_many defaults to { min: 0, max: nil } (unbounded)
      #   - has_many Things, max: 5 produces { min: 0, max: 5 }
      # Mirrors Rust's ir::Cardinality for JSON parity (codegen/ir_shape
      # Cardinality + ReferenceKind fixtures land the structural side ;
      # this attr ports the Ruby side).
      attr_reader :cardinality

      def initialize(name:, type:, domain: nil, kind: nil, validate: :exists, cardinality: nil)
        @name = name.to_sym
        @type = type.to_s
        @domain = domain
        @kind = kind
        @validate = validate
        # Default to singular (max: 1) when no explicit cardinality is
        # passed — keeps reference_to call sites working unchanged.
        @cardinality = cardinality || { min: 0, max: 1 }
      end

      # Returns true if this is a cross-context reference.
      def cross_context?
        kind == :cross_context
      end
    end
    end
  end
end
