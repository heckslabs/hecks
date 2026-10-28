module Hecks
  module Bluebook
    # A context map as data: the contexts a system holds, who owns each, and how pairs of them
    # relate (ADR 0135). Declared first; `ModelCheck::ContextMapChecks` holds the wiring to it.
    #
    # How a map is written down (its file kind and builder) is a separate decision. This holds
    # only what any spelling of it must say.
    class ContextMap
      # The relationship kinds a map may declare. `separate_ways` is not one: it is the absence
      # of a relationship, kept in {#separate_ways}.
      KINDS = %i[customer_supplier conformist anticorruption_layer shared_kernel open_host
                 partnership].freeze

      # One context: its name and the team that owns it.
      Context = Struct.new(:name, :team, keyword_init: true)

      # One declared relationship between two contexts.
      #
      # `upstream` supplies and `downstream` consumes. `published` lists the upstream events a
      # downstream may depend on; `shared` the names two contexts hold in common (shared kernel).
      # `acknowledged` maps a finding kind about the relationship to the reason it is allowed.
      Relationship = Struct.new(:upstream, :downstream, :kind, :published, :shared, :acknowledged,
                                keyword_init: true) do
        # @return [Array(String, String)] the two contexts, sorted, whichever way the arrow runs
        def pair = [upstream, downstream].sort

        # @return [Boolean] whether the relationship allows a finding of this kind
        def acknowledges?(finding) = (acknowledged || {}).key?(finding.to_sym)
      end

      attr_reader :name, :contexts, :relationships, :separate_ways

      # @param name [String] the system the map covers
      # @param contexts [Array<Context>] every context the system holds
      # @param relationships [Array<Relationship>] the declared relationships
      # @param separate_ways [Array<Array(String, String)>] pairs declared apart
      # @raise [ArgumentError] on an unknown kind, or a relationship or pair naming an undeclared
      #   context
      def initialize(name:, contexts: [], relationships: [], separate_ways: [])
        @name          = name.to_s
        @contexts      = contexts
        @relationships = relationships
        @separate_ways = separate_ways.map { |pair| pair.map(&:to_s).sort }
        refuse_unknown_kinds!
        refuse_undeclared_contexts!
      end

      # @return [Array<String>] the declared contexts' names
      def context_names = contexts.map { |context| context.name.to_s }

      # @param left [String] a context's name
      # @param right [String] another context's name
      # @return [Array<Relationship>] the relationships declared between them, either way round
      def relationships_between(left, right)
        pair = [left.to_s, right.to_s].sort
        relationships.select { |relationship| relationship.pair == pair }
      end

      # @return [Boolean] whether the map declares the two contexts apart
      def separate?(left, right) = separate_ways.include?([left.to_s, right.to_s].sort)

      private

      def refuse_unknown_kinds!
        unknown = relationships.map(&:kind).uniq - KINDS
        return if unknown.empty?

        raise ArgumentError, "unknown relationship kind #{unknown.first.inspect} (known: #{KINDS.inspect})"
      end

      def refuse_undeclared_contexts!
        named = (relationships.flat_map { |relationship| [relationship.upstream, relationship.downstream] } +
                 separate_ways.flatten).map(&:to_s).uniq
        missing = named - context_names
        return if missing.empty?

        raise ArgumentError, "#{name} relates #{missing.join(", ")}, which it does not declare as a context"
      end
    end
  end
end
