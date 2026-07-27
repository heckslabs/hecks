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
# rule here. Every aggregate says which backing it wants, in the hecksagon.
#
# A domain with NO HECKSAGON gets the internal Memory adapter for every
# aggregate. That is the override principle : a hecksagon bind changes which
# adapter answers, it is not what makes persistence exist. Memory is an ordinary
# adapter — same port, same contract, same attach checkpoint — that the runtime
# always carries, so a bluebook runs before anyone has written a hecksagon.
#
# But a domain that DOES declare a hecksagon is deciding its wiring, and an
# aggregate left out of it is a forgotten decision rather than an absent one.
# That is an error. The distinction is intent : nothing decided means nothing
# forgotten, and `Cart.persisted_by("Memory")` says in-memory ON PURPOSE.
#
#   Ports::Persistence.repository(registry, "Pizzas", pizza_ir)  # => Adapters::Sqlite
module Hecksagain
  module Ports
    module Persistence
      NAME = "persistence"
      VERB = "persisted_by"

      # The adapter the runtime always carries. Not a fallback code path — a
      # real adapter, declared in memory.adapter, resolved through the same
      # checkpoint as any other. See `bind_for`.
      DEFAULT_ADAPTER = "Memory"

      module_function

      # The adapter instance backing one aggregate. Memoisation belongs to the
      # registry — it owns the boot's lifetime, this owns the resolution.
      def repository(registry, domain, aggregate)
        bind = bind_for(registry, domain, aggregate)

        # The attach checkpoint lives on the registry, so the boot-time sweep
        # (verify!) and this resolution spend the SAME check rather than two
        # copies that could drift.
        registry.check_verb(bind)

        settings = registry.world(domain)&.for_verb(bind.verb) || {}
        registry.check_settings(bind, settings)

        registry.adapter_class(bind.adapter)
                .new(aggregate: aggregate, settings: settings, root: registry.root)
      end

      # The bind an aggregate resolves through — the one it DECLARES, or the
      # internal default.
      #
      # Memory is an adapter like any other : it declares the persistence port
      # in memory.adapter, implements the same find/all/count/save contract,
      # and type-checks through the same attach checkpoint below. What makes
      # it the default is only that the runtime always carries it, so an
      # aggregate that names no backing still gets a real repository rather
      # than an error.
      #
      # WIRING IS OVERRIDE, NOT SUBSTRATE. A hecksagon bind changes which
      # adapter answers ; it is not what makes persistence work at all. So a
      # bluebook runs before anyone has written a hecksagon, and a grammar
      # chapter — reasoned about far more often than stored — need not claim a
      # database to be dispatchable.
      #
      # A HECKSAGON IS EVIDENCE OF INTENT. Writing one says the wiring is
      # being decided ; an aggregate left out of it is a FORGOTTEN decision,
      # not an absent one, and defaulting there would be the silence this
      # whole port exists to refuse — a domain that meant to persist, looking
      # entirely correct while nothing was written.
      #
      # So the default belongs only to a domain that declares no hecksagon at
      # all : nothing has been decided, so nothing was forgotten. A domain
      # that genuinely wants an aggregate in memory says so —
      # `Cart.persisted_by("Memory")` is a decision, and reads as one.
      def bind_for(registry, domain, aggregate)
        hexagon = registry.hecksagon(domain)
        return default_bind(aggregate) unless hexagon

        hexagon.bind_for(aggregate.name, VERB) || raise(
          Runtime::WiringError,
          "#{domain}::#{aggregate.name} has no #{VERB} bind. #{domain} declares a " \
          "hecksagon, so its wiring is being decided explicitly and an aggregate " \
          "left out is a forgotten decision. Bind it, or say " \
          "#{aggregate.name}.#{VERB}(#{DEFAULT_ADAPTER.inspect}) to keep it in " \
          "memory on purpose."
        )
      end

      # The internal adapter, as a bind. Synthesised rather than special-cased
      # so it travels the SAME path a declared bind does — port lookup, verb
      # check, settings, construction. A default that skipped those checks
      # would be a second, untested wiring path.
      def default_bind(aggregate)
        Bluebook::IR::Bind.new(
          aggregate: aggregate.name,
          verb:      VERB,
          adapter:   DEFAULT_ADAPTER
        )
      end


    end
  end
end
