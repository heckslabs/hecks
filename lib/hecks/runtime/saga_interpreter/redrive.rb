require_relative "../outbox"

module Hecks
  module Runtime
    class SagaInterpreter
      # Finishes a saga leg a crash cut short. The pending marker names the moving event and how
      # many of the leg's dispatches settled, so the ones that never began are delivered now. The one
      # that may have run is delivered again only when its command is declared idempotent; otherwise
      # it is reported, since a second delivery could apply it twice. Mixed into {SagaInterpreter}.
      module Redrive
        # One rehydrated instance a crash left mid-leg: its declaration, correlation, home domain,
        # the instance itself and the marker the crash left on it.
        Stalled = Struct.new(:process_manager, :correlation, :domain, :instance, :marker) do
          # @return [String] the instance named the way a warning names it
          def label = "#{process_manager.name} instance #{correlation.inspect}"

          # @return [String] the declared name of the saga
          def saga_name = process_manager.name

          # @return [Hash{Symbol => Object}] the log record a leg redriven from this stall starts with
          def record = { process_manager: saga_name, on: marker[:on], instance: correlation, redriven: true }

          # @return [Hash{Symbol => Object}] the log row that reports this stall for a human to reconcile
          def stall_row = { process_manager: saga_name, instance: correlation, rehydrated_stalled: true }

          # @return [Integer] how many of the leg's dispatches had settled
          def settled = marker[:settled].to_i

          # @return [Boolean] whether the dispatch after the settled ones had been started
          def attempting? = marker[:attempting] ? true : false
        end

        # Redrives every stalled instance of `domain` the registry rehydrated.
        #
        # @param domain [String, Symbol] the domain whose stalled instances are finished
        # @return [void]
        def redrive_stalled(domain)
          bluebook = @registry.bluebook(domain)
          return unless bluebook

          bluebook.process_managers.each do |process_manager|
            stalled_instances(process_manager).each do |correlation, instance|
              redrive_instance(process_manager, correlation, instance, domain)
            end
          end
        end

        private

        def stalled_instances(process_manager)
          @registry.saga_instances[process_manager.name].select { |_, instance| instance[:stalled] }
        end

        def redrive_instance(process_manager, correlation, instance, domain)
          stalled = Stalled.new(process_manager, correlation, domain, instance, instance.delete(:stalled))
          leg     = stalled_leg(stalled)
          leg ? resume_leg(leg, stalled) : report_unredrivable(stalled)
        end

        def resume_leg(leg, stalled)
          remaining = leg.dispatches.drop(stalled.settled)
          remaining = withhold_ambiguous(leg, stalled, remaining) if stalled.attempting?
          deliver_dispatches(leg, remaining, from: leg.dispatches.size - remaining.size)
          finish_stalled(leg) if leg.progress[:settled] == leg.dispatches.size
        end

        # The leg the marker describes, or nil when it can't be rebuilt safely: the handler is gone,
        # or it is an unwinding leg whose derived compensations may be half drained.
        def stalled_leg(stalled)
          marker = stalled.marker
          return nil if marker[:on] == REFUSED && stalled.instance[:completed_compensations].to_a.any?

          handler = stalled.process_manager.handler_for(marker[:on], marker[:from])
          return nil unless handler && handler.to_state == stalled.instance[:state]

          build_stalled_leg(stalled, handler)
        end

        def build_stalled_leg(stalled, handler)
          event = Outbox.event_from(stalled.marker[:event])
          leg   = Leg.new(stalled.process_manager, event, stalled.domain, stalled.correlation, stalled.record,
                          stalled.instance)
          leg.handler = handler
          leg.pre_state = stalled.marker[:from]
          leg.progress.merge!(settled: stalled.settled, attempting: false)
          leg
        end

        # The marker says the next dispatch was started, so it may have run. An idempotent command
        # is delivered again; for any other the leg stays stalled and is reported.
        def withhold_ambiguous(leg, stalled, remaining)
          return remaining if remaining.empty? || command_idempotent?(leg.domain, remaining.first.command_name)

          report_ambiguous(leg, stalled, remaining.first)
          []
        end

        def report_ambiguous(leg, stalled, spec)
          warn "[hecks] #{leg.domain} #{stalled.label} stalled before #{spec.command_name} settled: it may " \
               "already have run and is not declared idempotent, so it was not redelivered; reconcile this " \
               "instance by hand."
          @registry.saga_log << stalled.stall_row.merge(ambiguous: spec.command_name, pending: stalled.marker)
          checkpoint_leg(leg, pending: leg.pending_marker.merge(attempting: true))
        end

        def report_unredrivable(stalled)
          marker = stalled.marker
          warn "[hecks] #{stalled.label} stalled mid-leg (#{marker[:on].inspect}, #{marker[:from].inspect} -> " \
               "#{marker[:to].inspect}) and cannot be redriven safely; reconcile this instance by hand."
          @registry.saga_log << stalled.stall_row.merge(state: stalled.instance[:state], pending: marker)
        end

        def finish_stalled(leg)
          log_leg(leg, redriven: true)
          clear_pending_marker(leg)
        end

        # Whether the command is declared safe to deliver twice.
        def command_idempotent?(domain, command_name)
          command = declared_commands(domain).find { |declared| declared.name == command_name }
          command.respond_to?(:idempotent?) && command.idempotent?
        end

        def declared_commands(domain) = @registry.bluebook(domain).aggregates.flat_map(&:commands)
      end
    end
  end
end
