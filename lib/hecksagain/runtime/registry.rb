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
      attr_reader :root, :bluebooks, :hecksagons, :ports, :adapters, :worlds, :event_log

      def initialize(root: nil)
        @root         = root
        @bluebooks    = {}
        @hecksagons   = {}
        @ports     = {}
        @adapters     = {}
        @worlds       = {}
        @event_log    = []
        @repositories = {}
      end

      def add_bluebook(item)  = @bluebooks[item.name]  = item
      def add_hecksagon(item) = @hecksagons[item.domain] = item
      def add_port(item)    = @ports[item.name]   = item
      def add_adapter(item)   = @adapters[item.name]   = item
      def add_world(item)     = @worlds[item.domain]   = item

      def bluebook(name)  = @bluebooks[name.to_s]
      def hecksagon(name) = @hecksagons[name.to_s]
      def world(name)     = @worlds[name.to_s]

      # Every command in every loaded domain, as fully-qualified verbs.
      def verbs = @bluebooks.values.flat_map(&:verbs).sort

      # Resolve (and memoise) the persistence adapter instance for an
      # aggregate. The RESOLUTION lives with its port
      # (ports/persistence/persistence.rb) ; what belongs here is the boot's
      # lifetime — one adapter per aggregate, built once.
      def repository(domain, aggregate)
        @repositories[[domain.to_s, aggregate.name]] ||=
          Ports::Persistence.repository(self, domain, aggregate)
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

      # Generic port machinery — PUBLIC, because the port modules under ports/
      # are its callers. A port resolves its own binds ; the registry only holds
      # what one boot loaded and answers questions about it.

      # The world block answers to the ADAPTER. A value named here that the
      # adapter does not declare is refused at boot rather than ignored — a
      # silently dropped setting is how a deployment ends up pointing
      # somewhere nobody intended, and the misspelling that caused it reads
      # perfectly well.
      def check_settings(bind, settings)
        adapter = @adapters[bind.adapter]
        return unless adapter

        declared = settings.keys - [:adapter]
        unknown  = declared.reject { |field| adapter.declares?(field) }
        return if unknown.empty?

        raise WiringError,
              "#{bind.adapter} does not declare #{unknown.map(&:inspect).join(', ')} — " \
              "it declares #{adapter.all_fields.map(&:inspect).join(', ')}. " \
              "Add the field to the adapter, or remove it from the world."
      end

      def port_for(bind)
        adapter = @adapters[bind.adapter]
        raise WiringError, "unknown adapter #{bind.adapter.inspect}" unless adapter

        @ports[adapter.port] ||
          raise(WiringError, "adapter #{bind.adapter} declares unknown port #{adapter.port.inspect}")
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
