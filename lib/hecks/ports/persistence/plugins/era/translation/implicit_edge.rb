require_relative "../projected_bluebook"
require_relative "additive_shape"

module Hecks
  module Translation
    # The empty edge a shape change needs when no edge file is written.
    #
    # A change that scaffolds to no rule, no unresolved line and no retirement, and whose storage
    # change only adds, carries every row unchanged, so no file has to say so. The boot and the mint
    # treat it as an empty edge from the held shape to the current one, and the journal records the
    # era it minted as implicit. Every other change still needs a real edge file.
    class ImplicitEdge
      # What the journal stores for an era minted under an implicit edge. A later boot reads
      # it back, so an audit can tell the edge was never written by hand.
      RECORD = { kind: "implicit", scaffolded: true }.freeze

      attr_reader :domain, :from, :to

      # @param domain [String] the domain the edge belongs to
      # @param from [String] the shape label the edge leaves
      # @param to [String] the shape label the edge reaches
      def initialize(domain:, from:, to:)
        @domain = domain
        @from = from
        @to = to
      end

      # An implicit edge declares no aggregate, so it renames, moves, converts and drops nothing.
      #
      # @return [Array] always empty
      def aggregates = []

      # An implicit edge retires no aggregate, as a written edge's `retired` lists none it drops.
      #
      # @return [Array] always empty
      def retired = []

      # @param _name [String, Symbol] an aggregate name
      # @return [nil] an implicit edge has no rules for any aggregate
      def for_aggregate(_name) = nil

      # @return [Boolean] always true
      def implicit? = true

      # The era record a mint writes for this edge, keyed by the label of the era it reaches.
      #
      # @return [Hash] `label` and `edge`, as the journal stores them
      def record = { label: to, edge: RECORD }

      # Whether a storage change needs no edge file: the scaffold finds no rule, no retirement and
      # no unresolved name, and every aggregate both shapes have only adds: same identity and
      # lifecycle field, every held attribute held exactly as before (list or scalar included),
      # and every attribute gained optional. Anything this cannot tell is breaking.
      #
      # @param diff [Hash] the scaffold's diff of the held shape against the current one
      # @param held [Hash, Runtime::ProjectedBluebook, Bluebook::Declaration] the held era's storage
      #   shape, a view over it, or a declared bluebook
      # @param current [Bluebook::Declaration] the current bluebook, which says which of its
      #   attributes are optional
      # @return [Boolean]
      def self.qualifies?(diff, held, current)
        diff[:aggregates].empty? && diff[:retired].empty? && diff[:unclaimed].empty? &&
          AdditiveShape.additive?(held, current)
      end
    end
  end
end
