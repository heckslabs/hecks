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
# An aggregate that says NOTHING gets the internal Memory adapter. That is the
# override principle : a hecksagon bind changes which adapter answers, it is not
# what makes persistence exist. Memory is an ordinary adapter — same port, same
# contract, same attach checkpoint — that the runtime happens to always carry,
# so an undeclared aggregate still gets a real repository rather than an error.
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
      # THE COST, NAMED : a domain that wires some aggregates and forgets one
      # gets Memory for the one it forgot, and looks entirely correct while
      # nothing is written for it. `registry.verify!` still resolves every
      # DECLARED bind eagerly, so a bind that is wrong fails at boot — but a
      # bind that is absent cannot be distinguished from one never wanted.
      # Tightening that is one condition here (default only when the domain
      # declares no persistence at all) if the silence ever costs more than
      # the convenience.
      def bind_for(registry, domain, aggregate)
        registry.hecksagon(domain)&.bind_for(aggregate.name, VERB) ||
          default_bind(aggregate)
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
