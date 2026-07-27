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
      attr_reader :root, :bluebooks, :hecksagons, :ports, :adapters, :worlds, :event_log,
                  :reaction_log

      def initialize(root: nil)
        @root         = root
        @bluebooks    = {}
        @hecksagons   = {}
        @ports     = {}
        @adapters     = {}
        @worlds       = {}
        @event_log    = []
        # Every policy that FIRED, and whether its command was delivered. A
        # reaction nobody records is a reaction nobody misses — which is how four
        # declared policies ran nowhere while parity stayed green.
        @reaction_log = []
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
        verify_default_adapter!

        @hecksagons.each_value do |hexagon|
          hexagon.binds.each do |bind|
            aggregate = bluebook(hexagon.domain)&.aggregate(bind.aggregate_name)
            raise WiringError, "#{bind.aggregate} is bound but not declared in the bluebook" unless aggregate

            # THE ATTACH CHECKPOINT, for EVERY declared bind — not only the
            # persistence one. `repository` below resolves the aggregate's
            # persisted_by bind and ignores whichever bind we are iterating, so
            # a bind on any other verb was never verb-checked at all. A spec
            # named "refuses a bind whose adapter cannot satisfy the verb" wired
            # `Pizza.charged_by("Memory")` and passed — on the unrelated error
            # that Pizza had no persisted_by bind. Once an unbound aggregate got
            # the Memory default that accident vanished and the gap showed.
            check_verb(bind)

            repository(hexagon.domain, aggregate)
          end
        end
        self
      end

      # THE DEFAULT ADAPTER MUST ACTUALLY BE THERE.
      #
      # An aggregate with no bind resolves through a synthesised bind naming
      # Ports::Persistence::DEFAULT_ADAPTER — a STRING, matched against a
      # declaration that arrives by a glob in the Folder adapter's
      # `load_library`, backed by a class that arrives by a require in
      # hecksagain.rb. Three independent things that have to meet, none of them
      # checked, and all of them reliable right up until one is renamed.
      #
      # Unchecked, a break surfaces as `unknown adapter "Memory"` at first save
      # — legible, but late, and raised on a path the author never wrote, which
      # is the worst place to learn it. The default is the one bind nobody
      # declares, so it is the one bind nobody would think to look at.
      #
      # Proving it costs one lookup : resolve it exactly as a real bind would.
      def verify_default_adapter!
        name = Ports::Persistence::DEFAULT_ADAPTER

        check_verb(
          Bluebook::IR::Bind.new(
            aggregate: "(default)",
            verb:      Ports::Persistence::VERB,
            adapter:   name
          )
        )
        adapter_class(name)
        self
      rescue WiringError => error
        raise WiringError,
              "the default persistence adapter (#{name}) is not usable, so an " \
              "aggregate with no bind could not be given one: #{error.message}"
      end

      # An adapter may exist, be spelled correctly, and still be the wrong KIND
      # of edge. Memory implements persistence and cannot charge, and that is
      # caught here — at boot, rather than at first fire.
      def check_verb(bind)
        port = port_for(bind)
        return if port.verb.to_s == bind.verb.to_s

        raise WiringError,
              "#{bind.adapter} implements the #{port.name} port (verb #{port.verb}) " \
              "and cannot satisfy #{bind.verb}"
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
