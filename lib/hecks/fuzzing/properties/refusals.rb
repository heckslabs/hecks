module Hecks
  module Fuzzing
    module Properties
      # Property: a refused dispatch changes nothing. Its stored records, journal entries,
      # events, reactions, saga advances and outbox rows read the same after the refusal as
      # before the dispatch. Entries without both snapshots (hand-built histories) are skipped.
      module Refusals
        # The parts of a snapshot compared, each named as a finding reports it.
        REFUSAL_TRACE_PARTS = %i[instances journal events reactions sagas outbox].freeze

        # Checks that every refused dispatch left every part of the runtime as it found it.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true if no refusal changed anything; otherwise a
        #   semicolon-joined message naming each refusal and what it changed
        def refusals_leave_no_trace(history)
          offenders = Array(history[:refusal_traces]).filter_map { |entry| refusal_offender(entry) }
          offenders.empty? || offenders.join("; ")
        end

        # The message for one refusal that changed something, or nil.
        def refusal_offender(entry)
          before = entry[:before]
          after  = entry[:after]
          return unless before && after

          changed = REFUSAL_TRACE_PARTS.reject { |part| before[part] == after[part] }
          return if changed.empty?

          "#{entry[:verb]} refused (#{entry[:kind]}) but changed #{changed.join(", ")}"
        end
      end
    end
  end
end
