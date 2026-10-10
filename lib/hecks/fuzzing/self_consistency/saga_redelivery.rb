require "tmpdir"
require_relative "../../runtime/saga_interpreter"

module Hecks
  module Fuzzing
    module SelfConsistency
      # The saga redelivery check: a rehydrated checkpoint must not advance when its last event
      # is redelivered. Mixed into `SelfConsistency`, whose `guarded_heki` and saga helpers it uses.
      module SagaRedelivery
        # One redelivery probe: the runtime and interpreter it runs on, the saga it re-advances,
        # and the event it redelivers.
        Redelivery = Struct.new(:runtime, :interpreter, :domain_name, :process_manager, :anchor,
                                :correlation, :saga, :event)

        # A rehydrated saga checkpoint must not advance when its last event is redelivered.
        #
        # The live registry slot is swapped for the cold-read checkpoint and restored in `ensure`;
        # safe because nothing reads the live registry after this runs. Only state/memory are
        # compared: a leg whose `from:` and `to:` match legitimately re-runs.
        def check_saga_idempotency(runtime, history)
          interpreter = Runtime::SagaInterpreter.new(runtime.registry, dispatcher: runtime)

          saga_groups(runtime, history).flat_map do |domain_name, process_manager, anchor, persisted|
            persisted.filter_map do |correlation, saga|
              redelivery = last_advancing_event(runtime, interpreter, process_manager, correlation)
              next unless redelivery

              check_one_saga_redelivery(Redelivery.new(runtime, interpreter, domain_name, process_manager,
                                                       anchor, correlation, saga, redelivery))
            end
          end
        end

        # The domain event the correlation's current checkpoint last advanced on, or nil if it
        # never advanced. Skips the synthetic `REFUSED` trigger, which has no event to redeliver.
        #
        # Uses `send(:saga_correlation)` on purpose: the private method is the real correlation
        # logic, and reimplementing it here would only approximate it.
        def last_advancing_event(runtime, interpreter, process_manager, correlation)
          entry = last_advance_entry(runtime, process_manager, correlation)
          return nil unless entry

          runtime.events.reverse_each.find do |event|
            event.name == entry[:on] && interpreter.send(:saga_correlation, process_manager, event) == correlation
          end
        end

        # The newest saga-log row in which the correlation advanced on a real event.
        def last_advance_entry(runtime, process_manager, correlation)
          runtime.registry.saga_log.reverse_each.find do |row|
            row[:process_manager] == process_manager.name && row[:instance] == correlation &&
              row[:advanced] && row[:on] != Runtime::SagaInterpreter::REFUSED
          end
        end

        # One correlation's redelivery check, split out of `check_saga_idempotency`.
        def check_one_saga_redelivery(redelivery)
          Dir.mktmpdir("hecks-self-consistency-saga") do |tmp|
            checkpoint = cold_checkpoint(redelivery, tmp)
            next unless checkpoint

            probe_redelivery(redelivery, checkpoint)
          end
        end

        # Writes the live saga through Heki and reads it back cold: `[state, memory,
        # compensations]`, or nil when the cold read does not find it.
        def cold_checkpoint(redelivery, tmp)
          saga = redelivery.saga
          heki_for(redelivery, tmp).save_saga(process_manager: redelivery.process_manager.name,
                                              correlation: redelivery.correlation.to_s, state: saga[:state],
                                              memory: saga[:memory], completed_compensations: [])

          rehydrated = heki_for(redelivery, tmp).each_saga.find { |_pm, corr, *| corr == redelivery.correlation.to_s }
          rehydrated&.drop(2)
        end

        def heki_for(redelivery, tmp)
          guarded_heki(aggregate: redelivery.anchor, root: tmp, settings: { domain: redelivery.domain_name })
        end

        # Redelivers the event to the cold-read checkpoint and reports any state/memory change.
        def probe_redelivery(redelivery, checkpoint)
          state, memory, = checkpoint
          before = { state: state, memory: deep_stringify_keys(memory) }
          registry = redelivery.runtime.registry
          saga_instances = registry.saga_instances[redelivery.process_manager.name]

          preserving_saga(saga_instances, redelivery.correlation, registry.saga_log) do
            redelivery_finding(redelivery, before, advanced_saga(redelivery, saga_instances, checkpoint))
          end
        end

        # Swaps the cold-read checkpoint into the live slot, redelivers the event, and answers
        # the slot as the redelivery left it.
        def advanced_saga(redelivery, saga_instances, checkpoint)
          state, memory, compensations = checkpoint
          saga_instances[redelivery.correlation] = { state: state, memory: memory,
                                                     completed_compensations: compensations || [] }
          redelivery.interpreter.advance(redelivery.event, redelivery.domain_name, only: redelivery.process_manager)
          saga_instances[redelivery.correlation]
        end

        # The finding for a redelivery that moved the saga, or nil.
        def redelivery_finding(redelivery, before, after)
          after_shape = after && { state: after[:state], memory: deep_stringify_keys(after[:memory]) }
          return if after_shape == before

          { field: "saga_redelivery_idempotency", domain: redelivery.domain_name,
            process_manager: redelivery.process_manager.name, correlation: redelivery.correlation,
            on: redelivery.event.name, before: before, after: after_shape }
        end

        # Runs the block, then puts the live saga slot back and slices off any `saga_log` rows the
        # probe appended: `advance` appends to the log (shared by reference with the primary
        # trace), and the probe must not leak into it.
        def preserving_saga(saga_instances, correlation, saga_log)
          original      = saga_instances[correlation]
          saga_log_mark = saga_log.size
          yield
        ensure
          saga_log.slice!(saga_log_mark..) if saga_log.size > saga_log_mark

          if original
            saga_instances[correlation] = original
          else
            saga_instances.delete(correlation)
          end
        end
      end
    end
  end
end
