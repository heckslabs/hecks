module Hecks
  module Runtime
    class SagaInterpreter
      # The compensation ledger of a saga instance: legs that completed compensably are recorded
      # as they dispatch, popped back off if their own attempt fails, and replayed newest-first
      # when a later leg is refused. Mixed into {SagaInterpreter}.
      module Compensation
        private

        # Recorded before dispatching, not after `@door.reenter` returns —
        # reenter can recursively re-enter this interpreter and refuse
        # before ever returning here, and recording only on success would
        # be too late for that nested refusal to see this leg's own
        # compensation. Popped back off in the rescues if this leg's own attempt is the one
        # that failed.
        def record_compensation(leg, spec, ledger)
          return unless spec.compensates && !ledger.recorded

          resolved = dispatch_args(leg.process_manager, spec.compensates, leg.event, leg.instance, leg.correlation)
          leg.instance[:completed_compensations] << { command_name: spec.compensates.command_name, args: resolved }
          checkpoint_leg(leg)
          ledger.recorded = true
        end

        # `.pop`, not search-and-delete — nothing else can have pushed after
        # this leg's own entry without this leg's own `reenter` having
        # already returned first.
        def unrecord_compensation(leg)
          leg.instance[:completed_compensations].pop
          checkpoint_leg(leg)
        end

        # Derived compensations run newest-first, before any hand-written
        # `on :refused` dispatches. Drained (popped), not just read —
        # that's what keeps a re-entrant `on :refused` from running twice.
        def drain_derived_compensations(leg)
          compensations = leg.instance[:completed_compensations] || []
          deliver_derived_compensation(leg, compensations.pop) until compensations.empty?
          checkpoint_leg(leg)
        end

        # `entry[:args]` is already resolved, so this skips `dispatch_args`
        # and goes straight to delivery. Never re-enters `unwind` on its own
        # failure — `compensation_failed: true` tags a refused compensation
        # distinctly rather than as an ordinary failed delivery.
        def deliver_derived_compensation(leg, entry)
          record = { process_manager: leg.process_manager.name, instance: leg.correlation,
                     dispatch: entry[:command_name] }
          attempts = 0
          loop do
            error = compensate_once(leg, entry, record)
            return unless error

            attempts += 1
            return abandon_compensation(leg, entry, record, error, attempts) if attempts > MAX_DEFECT_RETRIES

            log_compensation_retry(record, error, attempts)
          end
        end

        # One try. Answers nil once the compensation has settled (delivered or refused), or the
        # crash that stopped it.
        def compensate_once(leg, entry, record)
          reenter_command(leg, entry[:command_name], entry[:args], explicit: true, source_receiver: nil)
          @registry.saga_log << record.merge(delivered: true, compensation: true)
          nil
        rescue *DOMAIN_REFUSALS => e
          @registry.saga_log << record.merge(delivered: false, reason: e.message, compensation: true,
                                             compensation_failed: true)
          nil
        rescue StandardError => e
          e
        end

        def log_compensation_retry(record, error, attempt)
          @registry.saga_log << record.merge(delivered: false, reason: error.message, compensation: true,
                                             defect: true, error_class: error.class.name,
                                             attempt: attempt, retrying: true)
        end

        def abandon_compensation(leg, entry, record, error, attempt)
          warn "[hecks] defect compensating saga #{leg.process_manager.name} — instance #{leg.correlation.inspect} " \
               "dispatching #{entry[:command_name]} after #{attempt} attempts: #{error.class}: #{error.message}"
          @registry.saga_log << record.merge(delivered: false, reason: error.message, compensation: true,
                                             defect: true, error_class: error.class.name, compensation_failed: true)
        end
      end
    end
  end
end
