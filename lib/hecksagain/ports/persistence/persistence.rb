# Persistence — the port's execution : resolve an aggregate's bind to a live
# adapter, and refuse anything that does not type-check.
#
# This is the port SIDE of the inverted arrow, and the one place the typed
# attach checkpoint is actually spent : a bind resolves only if the named
# adapter's declared port carries the bind's how-verb. `Pizzas::Pizza
# .charged_by("Memory")` names a real adapter and a real verb and still fails,
# because Memory implements persistence and persistence does not charge.
#
# Unlike extraction, persistence binds PER AGGREGATE. A domain genuinely wants
# Sqlite for one root and Memory for another — the Cart that is discarded on
# checkout has no business claiming a database — so there is no single-adapter
# rule here. Every aggregate says which backing it wants, in the hecksagon, and
# an aggregate that says nothing is an error rather than a default.
#
#   Ports::Persistence.repository(registry, "Pizzas", pizza_ir)  # => Adapters::Sqlite
module Hecksagain
  module Ports
    module Persistence
      NAME = "persistence"
      VERB = "persisted_by"

      module_function

      # The adapter instance backing one aggregate. Memoisation belongs to the
      # registry — it owns the boot's lifetime, this owns the resolution.
      def repository(registry, domain, aggregate)
        bind = bind_for(registry, domain, aggregate)
        port = registry.port_for(bind)

        check_verb(bind, port)

        settings = registry.world(domain)&.for_verb(bind.verb) || {}
        registry.check_settings(bind, settings)

        registry.adapter_class(bind.adapter)
                .new(aggregate: aggregate, settings: settings, root: registry.root)
      end

      def bind_for(registry, domain, aggregate)
        hexagon = registry.hecksagon(domain)
        unless hexagon
          raise Runtime::WiringError, "no hecksagon loaded for #{domain}"
        end

        hexagon.bind_for(aggregate.name, VERB) ||
          raise(Runtime::WiringError, "#{domain}::#{aggregate.name} has no #{VERB} bind")
      end

      # The attach checkpoint. An adapter may exist, be spelled correctly, and
      # still be the wrong KIND of edge — that is what the verb comparison
      # catches, at boot, rather than at first save.
      def check_verb(bind, port)
        return if port.verb.to_s == bind.verb.to_s

        raise Runtime::WiringError,
              "#{bind.adapter} implements the #{port.name} port (verb #{port.verb}) " \
              "and cannot satisfy #{bind.verb}"
      end
    end
  end
end
