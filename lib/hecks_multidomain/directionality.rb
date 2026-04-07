# Hecks::Boot::EventDirectionality
#
# Introspects reactive policies across multiple domains to build a
# directionality map — which domains each domain needs to listen to.
# Used by boot_multi to create FilteredEventBus instances and by
# auto_wire to keep explicit config consistent with introspected wiring.
#
#   map = EventDirectionality.build(domains)
#   # => { "identity_domain" => ["model_registry_domain", "operations_domain"] }
#
module Hecks
  module MultiDomain
    # Builds a directionality map by introspecting reactive policies across
    # multiple domains. A reactive policy is one that reacts to an event from
    # another domain (e.g., +on PizzaOrdered, trigger: ReserveIngredients+).
    #
    # The directionality map tells each domain which other domains' events it
    # needs to receive. This is used by +boot_multi+ to create +FilteredEventBus+
    # instances that restrict event flow to only the declared directions.
    #
    # Also provides a +.validate+ method that compares introspected directionality
    # against explicit +listens_to+ declarations, returning warnings for any
    # mismatches where a policy needs events that are not declared.
    module Directionality
      # Build a map of gem_name -> array of source gem_names this domain
      # needs events from, based on reactive policy introspection.
      #
      # Algorithm:
      # 1. Collect all events across all domains, mapping event name to the
      #    gem_name of the domain that defines it (+event_origins+).
      # 2. For each domain, inspect all reactive policies (both aggregate-level
      #    and domain-level). If a policy reacts to an event from a different
      #    domain, record that domain as a listener of the event's source.
      #
      # @param domains [Array<Hecks::DomainModel::Structure::Domain>] all domains in the multi-domain setup
      # @return [Hash<String, Array<String>>] map of gem_name to array of source gem_names
      #   it needs to listen to. Only domains with cross-domain reactive policies appear as keys.
      def self.build(domains)
        event_origins = {}
        domains.each do |d|
          d.aggregates.each do |agg|
            agg.events.each { |e| event_origins[e.name] = d.gem_name }
          end
        end

        listeners = {}
        domains.each do |d|
          all_policies = d.aggregates.flat_map(&:policies) + (d.policies || [])
          all_policies.select(&:reactive?).each do |pol|
            source = event_origins[pol.event_name]
            next unless source && source != d.gem_name
            listeners[d.gem_name] ||= []
            listeners[d.gem_name] << source unless listeners[d.gem_name].include?(source)
          end
        end

        listeners
      end

      # Validate that explicit +listens_to+ declarations match what reactive policies
      # actually need. Returns warnings for any domain that has reactive policies
      # requiring events from a source domain but does not declare +listens_to+ for
      # that source.
      #
      # @param domains [Array<Hecks::DomainModel::Structure::Domain>] all domains
      # @param declarations [Hash<String, Array<String>>] explicit directionality
      #   declarations from the configuration (gem_name -> array of source gem_names)
      # @return [Array<String>] warning messages (empty if everything matches)
      def self.validate(domains, declarations)
        warnings = []
        introspected = build(domains)

        introspected.each do |gem_name, needed_sources|
          declared = declarations[gem_name]
          next unless declared # no declarations = open mode, skip

          needed_sources.each do |source|
            unless declared.include?(source)
              warnings << "#{gem_name} has policies reacting to #{source} events but does not declare listens_to \"#{source}\""
            end
          end
        end

        warnings
      end
    end
  end
end
