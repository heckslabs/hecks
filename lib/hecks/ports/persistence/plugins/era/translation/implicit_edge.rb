require_relative "../projected_bluebook"

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
      # no unresolved name, and every attribute an existing aggregate gained is optional.
      #
      # @param diff [Hash] the scaffold's diff of the held shape against the current one
      # @param held [Hash, Runtime::ProjectedBluebook, Bluebook::Declaration] the held era's storage
      #   shape, a view over it, or a declared bluebook; only its aggregate and attribute names
      #   are read
      # @param current [Bluebook::Declaration] the current bluebook, which says which of its
      #   attributes are optional
      # @return [Boolean]
      def self.qualifies?(diff, held, current)
        diff[:aggregates].empty? && diff[:retired].empty? && diff[:unclaimed].empty? &&
          new_attributes_optional?(Runtime::ProjectedBluebook.wrap(held), current)
      end

      # An aggregate the held era did not have is new: nothing stored before it, so its attributes
      # may be required.
      #
      # @return [Boolean]
      def self.new_attributes_optional?(held, current)
        held_names = held.aggregates.to_h { |aggregate| [aggregate.name, attribute_names(aggregate)] }
        current.aggregates.all? do |aggregate|
          !held_names.key?(aggregate.name) || gained_optional?(aggregate, held_names[aggregate.name])
        end
      end

      # @return [Boolean] whether every attribute an aggregate has that its held shape did not is
      #   optional
      def self.gained_optional?(aggregate, known)
        aggregate.attributes.all? { |attribute| known.include?(attribute.name) || attribute.optional? }
      end

      # @return [Array<String>] the names of an aggregate's attributes
      def self.attribute_names(aggregate) = aggregate.attributes.map(&:name)
      private_class_method :new_attributes_optional?, :gained_optional?, :attribute_names
    end
  end
end
