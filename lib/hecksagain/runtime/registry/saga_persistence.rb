module Hecksagain
  module Runtime
    class Registry
      # SAGA PERSISTENCE — no new DSL verb, no new world setting.
      # Whatever adapter a domain's own aggregates already use for
      # durability, its sagas use the same one, automatically: three
      # OPTIONAL adapter methods (`save_saga`/`delete_saga`/`each_saga`),
      # `respond_to?`-checked the same way `Ports::Persistence::AppendOnly`
      # already treats an adapter's own optional methods
      # (`find`/`all`/`count`/`reset!`/`events`/`record_event`).
      module SagaPersistence
        # Resolved and memoized per domain — the FIRST real aggregate
        # declared in the domain's own bluebook is the resolution
        # anchor. `Ports::Persistence::BindingPolicy.resolve` for that
        # aggregate already falls back to a domain-level default bind
        # (§0's `Hecksagon#bind_for`) before falling back to Memory, so
        # this needs no separate "was a default declared" branch of its
        # own — whatever adapter that anchor resolves to already IS the
        # domain's own default in the normal case (every aggregate
        # shares one adapter), and is the honest, documented fallback
        # for the rarer domain genuinely split across more than one
        # local adapter with no default declared.
        def saga_persistence(domain)
          (@saga_persistence ||= {})[domain.to_s] ||= resolve_saga_persistence(domain.to_s)
        end

        private

        def resolve_saga_persistence(domain)
          anchor = hecksagon(domain) && bluebook(domain)&.aggregates&.first
          return Ports::Persistence::NULL_SAGA_STORE unless anchor

          bind = Ports::Persistence::BindingPolicy.resolve(self, domain, anchor)
          return Ports::Persistence::NULL_SAGA_STORE if adapter_class(bind.adapter) <= Ports::Persistence::RemoteRuntime

          adapter = repository(domain, anchor).adapter
          adapter.respond_to?(:save_saga) ? adapter : Ports::Persistence::NULL_SAGA_STORE
        rescue WiringError
          # A domain not cleanly wired for its own anchor aggregate's
          # persistence (a test fixture binding only the aggregates it
          # exercises, say) degrades saga persistence to the same no-op
          # default an unbound domain gets — never raises out of a
          # dispatch that would otherwise have succeeded. Matches this
          # capability's own framing throughout: automatic wherever it's
          # cleanly supported, silently absent wherever it isn't.
          Ports::Persistence::NULL_SAGA_STORE
        end
      end
    end
  end
end
