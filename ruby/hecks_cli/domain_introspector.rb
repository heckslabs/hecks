module Hecks
  class CLI < Thor
    # Hecks::CLI::DomainIntrospector
    #
    # Analyzes cross-domain event wiring by introspecting reactive policies.
    # Builds maps of which domains produce events consumed by other domains'
    # policies, yielding listener (who I react to) and sender (who reacts to me)
    # relationships. All map keys use gem_name (snake_case) for consistency.
    #
    #   introspector = DomainIntrospector.new(domains)
    #   introspector.listeners   # { "identity_domain" => { "model_registry_domain" => [pol, ...] } }
    #   introspector.senders     # { "model_registry_domain" => { "identity_domain" => [pol, ...] } }
    #
    class DomainIntrospector
      # @return [Hash<String, Hash<String, Array>>] map of listener_gem_name =>
      #   { source_gem_name => [policies] }. For each domain, which other domains'
      #   events does it react to?
      attr_reader :listeners

      # @return [Hash<String, Hash<String, Array>>] map of source_gem_name =>
      #   { listener_gem_name => [policies] }. For each domain, which other domains
      #   consume its events?
      attr_reader :senders

      # Builds listener and sender maps by introspecting reactive policies
      # across all provided domains.
      #
      # @param domains [Array<BluebookModel::Structure::Domain>] all domains to analyze
      def initialize(domains)
        @gem_names = domains.each_with_object({}) { |d, h| h[d.name] = d.gem_name }
        origins = build_event_origin_map(domains)
        @listeners = build_listener_map(domains, origins)
        @senders = build_sender_map(@listeners)
      end

      private

      # Maps event names to the gem_name of the domain that produces them.
      #
      # @param domains [Array<BluebookModel::Structure::Domain>] all domains
      # @return [Hash<String, String>] event_name => gem_name
      def build_event_origin_map(domains)
        origins = {}
        domains.each do |d|
          d.aggregates.each do |agg|
            agg.events.each { |e| origins[e.name] = d.gem_name }
          end
        end
        origins
      end

      # Builds the listener map: for each domain, which reactive policies
      # listen to events from other domains?
      #
      # @param domains [Array<BluebookModel::Structure::Domain>] all domains
      # @param event_origins [Hash<String, String>] event_name => source gem_name
      # @return [Hash<String, Hash<String, Array>>] listener_gem => { source_gem => [policies] }
      def build_listener_map(domains, event_origins)
        listeners = {}
        domains.each do |d|
          all_policies = d.aggregates.flat_map(&:policies) + (d.policies || [])
          all_policies.select(&:reactive?).each do |pol|
            source = event_origins[pol.event_name]
            next unless source && source != d.gem_name
            listeners[d.gem_name] ||= {}
            listeners[d.gem_name][source] ||= []
            listeners[d.gem_name][source] << pol
          end
        end
        listeners
      end

      # Inverts the listener map to produce a sender map.
      #
      # For each source domain, which target domains consume its events?
      #
      # @param listeners [Hash<String, Hash<String, Array>>] the listener map
      # @return [Hash<String, Hash<String, Array>>] source_gem => { listener_gem => [policies] }
      def build_sender_map(listeners)
        senders = {}
        listeners.each do |listener_gem, sources|
          sources.each do |source_gem, policies|
            senders[source_gem] ||= {}
            senders[source_gem][listener_gem] ||= []
            policies.each { |pol| senders[source_gem][listener_gem] << pol }
          end
        end
        senders
      end
    end
  end
end
