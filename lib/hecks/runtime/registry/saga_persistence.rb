require_relative "../saga_pending_dispatch"
require_relative "saga_anchor"

module Hecks
  module Runtime
    class Registry
      # A domain's sagas persist through whatever adapter its aggregates already use;
      # `save_saga`/`delete_saga`/`each_saga` are optional, `respond_to?`-checked capabilities.
      # A process manager started by an aggregate the hecksagon binds on its own persists with
      # that aggregate's records instead (see {SagaAnchor}), so a saga lives where the record
      # that starts it lives.
      module SagaPersistence
        include SagaAnchor

        # The store one domain's sagas, or one of its process managers, checkpoint to. Memoized
        # per store via double-checked locking; never reuse @saga_mutex, see #initialize.
        #
        # @param domain [String, Symbol] the domain whose sagas are checkpointed
        # @param process_manager [Bluebook::ProcessManager, String, nil] one process manager,
        #   whose starting aggregate may hold it; the domain's own store when nil
        # @return [#save_saga] the adapter, or the null store when nothing can checkpoint
        def saga_persistence(domain, process_manager = nil)
          anchor = process_manager && saga_anchor(domain, process_manager)
          key = anchor ? "#{domain}::#{anchor.hecks_name}" : domain.to_s
          @saga_persistence[key] || @saga_persistence_mutex.synchronize do
            @saga_persistence[key] ||= anchor ? anchored_saga_store(domain, anchor) : resolve_saga_persistence(key)
          end
        end

        def saga_domains = @declared.hecksagons.keys | @declared.bluebooks.keys.select { |domain| default_adapter_for(domain) }

        # Whether any saga of the domain checkpoints somewhere that survives a restart.
        #
        # @param domain [String, Symbol] the domain whose sagas are asked about
        # @return [Boolean]
        def saga_durable?(domain)
          stores = [saga_persistence(domain), *routed_sagas(domain).values]
          stores.any? { |store| !store.equal?(Ports::Persistence::NULL_SAGA_STORE) }
        end

        # Boot-time-only (Loader.run_boot_gates!, before dispatch exists); no concurrent
        # writer to race here, unlike saga_interpreter.rb's writes under @saga_mutex. Each store
        # restores only the process managers that checkpoint to it; the domain's own store
        # restores every other one, including any the bluebook does not declare.
        def rehydrate_sagas!
          saga_domains.each do |domain|
            routed = routed_sagas(domain)
            restore_sagas(saga_persistence(domain)) { |name| !routed.key?(name) }
            routed.values.uniq.each { |store| restore_sagas(store) { |name| routed[name].equal?(store) } }
          end
          self
        end

        private

        # Restores the instances a store holds whose process manager the block accepts.
        def restore_sagas(store)
          store.each_saga do |process_manager, correlation, state, memory, completed_compensations = []|
            next unless yield(process_manager.to_s)

            pending = memory.delete(SAGA_PENDING_DISPATCH_KEY)
            @state.saga_instances[process_manager][correlation] =
              { state: state, memory: memory, completed_compensations: completed_compensations || [] }
            stall_saga(process_manager, correlation, pending) if pending
          end
        end

        # A pending marker left by a crash: state was checkpointed but the leg's dispatches did
        # not all settle. Held on the instance for `SagaInterpreter#redrive_stalled`, which runs
        # once the dispatcher exists; Heki's each_saga only symbolizes memory's top-level keys,
        # so the marker is normalized here once for all adapters.
        def stall_saga(process_manager, correlation, pending)
          @state.saga_instances[process_manager][correlation][:stalled] = pending.transform_keys(&:to_sym)
        end

        # A domain with no hecksagon resolves the same way: its world's `default_adapter` may keep
        # its records, and then it keeps its sagas too (ADR 0170).
        def resolve_saga_persistence(domain)
          anchor = bluebook(domain)&.aggregates&.first
          return Ports::Persistence::NULL_SAGA_STORE unless anchor

          persisting_adapter(domain, anchor)
        rescue WiringError
          # An unwired domain degrades to no saga persistence rather than raising mid-dispatch.
          Ports::Persistence::NULL_SAGA_STORE
        end

        # The starting aggregate's store when it can checkpoint sagas, else the domain's own.
        # Called under the resolution mutex, so the domain's store is memoized here directly.
        def anchored_saga_store(domain, anchor)
          store = persisting_adapter(domain, anchor)
          store.equal?(Ports::Persistence::NULL_SAGA_STORE) ? domain_saga_store(domain) : store
        rescue WiringError
          domain_saga_store(domain)
        end

        def domain_saga_store(domain) = (@saga_persistence[domain.to_s] ||= resolve_saga_persistence(domain.to_s))

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
