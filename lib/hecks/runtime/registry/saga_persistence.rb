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

        def saga_domains = @declared.hecksagons.keys | @declared.bluebooks.keys.select { |domain| default_adapter_for(domain) }

        # Boot-time-only (Loader.run_boot_gates!, before dispatch exists); no concurrent
        # writer to race here, unlike saga_interpreter.rb's writes under @saga_mutex.
        def rehydrate_sagas!
          saga_domains.each do |domain|
            saga_persistence(domain).each_saga do |process_manager, correlation, state, memory, completed_compensations = []|
              pending = memory.delete(SAGA_PENDING_DISPATCH_KEY)
              @state.saga_instances[process_manager][correlation] =
                { state: state, memory: memory, completed_compensations: completed_compensations || [] }
              stall_saga(process_manager, correlation, pending) if pending
            end
          end
          self
        end

        private

        # A pending marker left by a crash: state was checkpointed but the leg's dispatches did not all
        # settle. Held on the instance for `SagaInterpreter#redrive_stalled`, which runs once the
        # dispatcher exists; Heki's each_saga only symbolizes memory's top-level keys, so the
        # marker is normalized here once for all adapters.
        def stall_saga(process_manager, correlation, pending)
          @state.saga_instances[process_manager][correlation][:stalled] = pending.transform_keys(&:to_sym)
        end

        def resolve_saga_persistence(domain)
          anchor = hecksagon(domain) && bluebook(domain)&.aggregates&.first
          return Ports::Persistence::NULL_SAGA_STORE unless anchor

          persisting_adapter(domain, anchor)
        rescue WiringError
          # An unwired domain degrades to no saga persistence rather than raising mid-dispatch.
          Ports::Persistence::NULL_SAGA_STORE
        end

        # The anchor aggregate's own adapter when it can checkpoint sagas, else the null store.
        def persisting_adapter(domain, anchor)
          bind = Ports::Persistence::BindingPolicy.resolve(self, domain, anchor)
          return Ports::Persistence::NULL_SAGA_STORE if adapter_class(bind.adapter) <= Ports::Persistence::RemoteRuntime

          adapter = repository(domain, anchor).adapter
          adapter.respond_to?(:save_saga) ? adapter : Ports::Persistence::NULL_SAGA_STORE
        end
      end
    end
  end
end
