# Registry — everything one boot loaded, and the place binds are resolved.
#
# The typed attach checkpoint lives here: a bind resolves only if the named
# adapter's declared family carries the bind's how-verb. `verify!` runs that
# check for every bind at boot, so a misconfiguration surfaces on the first
# line of the session rather than on the first save.
#
#   registry.repository("Pizzas", pizza_ir)  # => Adapters::Sqlite
module Hecksagain
  module Runtime
    class WiringError < StandardError; end

    class Registry
      attr_reader :root, :bluebooks, :hecksagons, :families, :adapters, :worlds, :event_log

      def initialize(root: nil)
        @root         = root
        @bluebooks    = {}
        @hecksagons   = {}
        @families     = {}
        @adapters     = {}
        @worlds       = {}
        @event_log    = []
        @repositories = {}
      end

      def add_bluebook(item)  = @bluebooks[item.name]  = item
      def add_hecksagon(item) = @hecksagons[item.domain] = item
      def add_family(item)    = @families[item.name]   = item
      def add_adapter(item)   = @adapters[item.name]   = item
      def add_world(item)     = @worlds[item.domain]   = item

      def bluebook(name)  = @bluebooks[name.to_s]
      def hecksagon(name) = @hecksagons[name.to_s]
      def world(name)     = @worlds[name.to_s]

      # Every command in every loaded domain, as fully-qualified verbs.
      def verbs = @bluebooks.values.flat_map(&:verbs).sort

      # Resolve (and memoise) the persistence adapter instance for an aggregate.
      def repository(domain, aggregate)
        @repositories[[domain.to_s, aggregate.name]] ||= build_repository(domain, aggregate)
      end

      # Fail fast: resolve every declared bind now.
      def verify!
        @hecksagons.each_value do |hexagon|
          hexagon.binds.each do |bind|
            aggregate = bluebook(hexagon.domain)&.aggregate(bind.aggregate_name)
            raise WiringError, "#{bind.aggregate} is bound but not declared in the bluebook" unless aggregate

            repository(hexagon.domain, aggregate)
          end
        end
        self
      end

      private

      def build_repository(domain, aggregate)
        bind   = persistence_bind(domain, aggregate)
        family = family_for(bind)

        unless family.verb.to_s == bind.verb.to_s
          raise WiringError,
                "#{bind.adapter} implements the #{family.name} family (verb #{family.verb}) " \
                "and cannot satisfy #{bind.verb}"
        end

        settings = world(domain)&.for_verb(bind.verb) || {}
        adapter_class(bind.adapter).new(aggregate: aggregate, settings: settings, root: @root)
      end

      def persistence_bind(domain, aggregate)
        hexagon = hecksagon(domain)
        raise WiringError, "no hecksagon loaded for #{domain}" unless hexagon

        hexagon.bind_for(aggregate.name, "persisted_by") ||
          raise(WiringError, "#{domain}::#{aggregate.name} has no persisted_by bind")
      end

      def family_for(bind)
        adapter = @adapters[bind.adapter]
        raise WiringError, "unknown adapter #{bind.adapter.inspect}" unless adapter

        @families[adapter.family] ||
          raise(WiringError, "adapter #{bind.adapter} declares unknown family #{adapter.family.inspect}")
      end

      def adapter_class(name)
        Adapters.const_get(name)
      rescue NameError
        raise WiringError, "no Ruby adapter implementation for #{name.inspect} " \
                           "(expected Hecksagain::Adapters::#{name})"
      end
    end
  end
end
