module Hecks
  module Runtime
    # **What a booted or described domain declares**, asked of the thing that holds it.
    #
    # A caller holding a dispatcher (or a described domain) asks it for a chapter, a repository
    # or the translations, rather than reaching through its registry. The includer answers
    # `registry`.
    module Declarations
      # Every loaded chapter, by name.
      #
      # @return [Hash{String => Bluebook::Chapter}] the loaded chapters, keyed by name
      def bluebooks = registry.bluebooks

      # Exposes one loaded domain's bluebook.
      #
      # @param domain [String, Symbol] the domain name
      # @return [Bluebook::Bluebook, nil] the bluebook, or nil when no such domain is loaded
      def bluebook(domain) = registry.bluebook(domain)

      # The first chapter loaded: a one-domain boot's own bluebook.
      #
      # @return [Bluebook::Chapter, nil] the first loaded chapter, or nil when none loaded
      def first_bluebook = registry.first_bluebook

      # Answers whether a domain was loaded as a bounded chapter.
      #
      # @param domain [String, Symbol] the domain name
      # @return [Boolean] whether the domain is a bounded chapter
      def bounded?(domain) = registry.bounded?(domain)

      # The repository that stores `aggregate`.
      #
      # @param domain [String, Symbol] the domain `aggregate` belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate
      # @return [Persistence::AppendOnly] the aggregate's authoritative repository
      def repository(domain, aggregate) = registry.repository(domain, aggregate)

      # A domain's wiring.
      #
      # @param domain [String, Symbol] the domain name
      # @return [Bluebook::Hecksagon, nil] the wiring, or nil when none is registered
      def hecksagon(domain) = registry.hecksagon(domain)

      # A domain's world settings.
      #
      # @param domain [String, Symbol] the domain name
      # @return [Bluebook::World, nil] the world, or nil when none is registered
      def world(domain) = registry.world(domain)

      # Every declared translation between eras.
      #
      # @return [Array<Bluebook::Translation>] the loaded translations
      def translations = registry.translations

      # The privacy markings declared before their aggregate was loaded.
      #
      # @return [Array<Hash>] each marking's domain, attribute path, category and readers
      def pending_privacy_markings = registry.pending_privacy_markings

      # Every saga instance this boot has started.
      #
      # @return [Hash] the saga instances, by process manager and then correlation
      def saga_instances = registry.saga_instances
    end
  end
end
