module Hecks
  module Runtime
    class SagaInterpreter
      # Where a saga instance begins and ends: born on the event a process manager starts on,
      # forgotten on the one it ends on. Mixed into {SagaInterpreter}.
      module Lifecycle
        private

        def begin_saga(process_manager, event, domain)
          return unless event.name == process_manager.starts_on

          correlation = saga_correlation(process_manager, event)
          return log_unborn(process_manager, event) if correlation.to_s.empty?
          return unless instantiate_saga?(process_manager, event, domain, correlation)

          @registry.saga_log << { process_manager: process_manager.name, on: event.name,
                                  instance: correlation, born: true, state: process_manager.states.first }
        end

        def log_unborn(process_manager, event)
          @registry.saga_log << { process_manager: process_manager.name, on: event.name,
                                  born: false, reason: "no #{process_manager.correlates_by} in the payload" }
        end

        # Whether this call created the instance: false when one already remembers the correlation.
        def instantiate_saga?(process_manager, event, domain, correlation)
          @registry.saga_mutex.synchronize do
            next false if @registry.saga_instances[process_manager.name].key?(correlation)

            # `.dup` — a fresh saga's own memory starts as a copy of the
            # starting event's payload, never the frozen payload itself,
            # since memory is written into over the saga's lifetime.
            instance = { state: process_manager.states.first, memory: event.payload.dup, completed_compensations: [] }
            @registry.saga_instances[process_manager.name][correlation] = instance
            checkpoint(process_manager, correlation, instance, domain)
            true
          end
        end

        def end_saga(process_manager, event, domain)
          return unless event.name == process_manager.ends_on

          correlation = saga_correlation(process_manager, event)
          return if correlation.to_s.empty?
          return unless forget_saga?(process_manager, domain, correlation)

          @registry.saga_log << { process_manager: process_manager.name, on: event.name,
                                  instance: correlation, ended: true }
        end

        # Whether this call ended the instance: false when no instance remembered the correlation.
        def forget_saga?(process_manager, domain, correlation)
          @registry.saga_mutex.synchronize do
            next false unless @registry.saga_instances[process_manager.name].delete(correlation)

            @registry.saga_persistence(domain).delete_saga(process_manager: process_manager.name, correlation: correlation)
            true
          end
        end
      end
    end
  end
end
