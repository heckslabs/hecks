require_relative "../saga_pending_dispatch"

module Hecks
  module Runtime
    class Registry
      # A domain's sagas persist through whatever adapter its aggregates already use;
      # `save_saga`/`delete_saga`/`each_saga` are optional, `respond_to?`-checked capabilities.
      module SagaPersistence
        # Memoized per domain via double-checked locking; never reuse @saga_mutex, see #initialize.
        def saga_persistence(domain)
          key = domain.to_s
          @saga_persistence[key] || @saga_persistence_mutex.synchronize do
            @saga_persistence[key] ||= resolve_saga_persistence(key)
          end
        end

        def saga_domains = @hecksagons.keys | @bluebooks.keys.select { |domain| default_adapter_for(domain) }

        # Boot-time-only (Loader.run_boot_gates!, before dispatch exists); no concurrent
        # writer to race here, unlike saga_interpreter.rb's writes under @saga_mutex.
        # rubocop:disable-next Hecks/ThreadSharedIvarMutation
        def rehydrate_sagas!
          saga_domains.each do |domain|
            saga_persistence(domain).each_saga do |process_manager, correlation, state, memory, completed_compensations = []|
              pending = memory.delete(SAGA_PENDING_DISPATCH_KEY)
              @saga_instances[process_manager][correlation] =
                { state: state, memory: memory, completed_compensations: completed_compensations || [] }
              warn_stalled_saga(domain, process_manager, correlation, state, pending) if pending
            end
          end
          self
        end

        private

        # A pending dispatch marker left by a crash: state was checkpointed but the dispatch
        # cascade it justifies may never have run. Surfaced as a warning, never auto-redriven.
        # rubocop:disable-next Hecks/ThreadSharedIvarMutation -- same
        def warn_stalled_saga(domain, process_manager, correlation, state, pending)
          # Heki's each_saga only symbolizes memory's top-level keys, not nested values;
          # Postgres/SQLite/D1 already return symbol keys. Normalize here once for all adapters.
          pending    = pending.transform_keys(&:to_sym)
          dispatches = Array(pending[:dispatches]).join(", ")
          warn "[hecks] #{domain} rehydrated #{process_manager} instance #{correlation.inspect} in state " \
               "#{state.inspect} with a dispatch left pending from before the last crash/restart — " \
               "#{dispatches} (on #{pending[:on].inspect}, #{pending[:from].inspect} -> #{pending[:to].inspect}) " \
               "may or may not have actually run. hecks does not auto-redrive a pending saga dispatch (that " \
               "needs idempotent delivery, which this pipeline doesn't have yet); reconcile this instance by hand."
          @saga_log << { process_manager: process_manager, instance: correlation, rehydrated_stalled: true,
                         state: state, pending: pending }
        end

        def resolve_saga_persistence(domain)
          anchor = hecksagon(domain) && bluebook(domain)&.aggregates&.first
          return Ports::Persistence::NULL_SAGA_STORE unless anchor

          bind = Ports::Persistence::BindingPolicy.resolve(self, domain, anchor)
          return Ports::Persistence::NULL_SAGA_STORE if adapter_class(bind.adapter) <= Ports::Persistence::RemoteRuntime

          adapter = repository(domain, anchor).adapter
          adapter.respond_to?(:save_saga) ? adapter : Ports::Persistence::NULL_SAGA_STORE
        rescue WiringError
          # An unwired domain degrades to no saga persistence rather than raising mid-dispatch.
          Ports::Persistence::NULL_SAGA_STORE
        end
      end
    end
  end
end
