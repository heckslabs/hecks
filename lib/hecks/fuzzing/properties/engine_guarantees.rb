module Hecks
  module Fuzzing
    module Properties
      # Properties over the dispatch pipeline itself, not any one domain's rules: a refused
      # command changes nothing, and state only changes alongside a journaled event.
      # Entries without before/after snapshots (hand-built histories) are skipped.
      module EngineGuarantees
        # Every refused dispatch left the instances and the event count as they were.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each refused verb that left a trace
        def refusals_leave_state_untouched(history)
          offenders = Array(history[:dispatch_traces]).filter_map do |trace|
            next unless trace[:refused]

            changes = trace_changes(trace)
            next if changes.empty?

            "refused #{trace[:verb]} left a trace: #{changes.join(', ')}"
          end

          offenders.empty? || offenders.join("; ")
        end

        # Every accepted dispatch that changed an instance also journaled at least one event.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each dispatch that changed state silently
        def state_changes_are_journaled(history)
          offenders = Array(history[:dispatch_traces]).filter_map do |trace|
            next if trace[:refused]
            next if trace[:before][:instances] == trace[:after][:instances]
            next if trace[:after][:events] > trace[:before][:events]

            "#{trace[:verb]} changed state without emitting an event"
          end

          offenders.empty? || offenders.join("; ")
        end

        private

        def trace_changes(trace)
          changes = []
          before = trace[:before]
          after  = trace[:after]
          changes << "events #{before[:events]} -> #{after[:events]}" unless before[:events] == after[:events]
          changes << "instances changed" unless before[:instances] == after[:instances]
          changes
        end
      end
    end
  end
end
