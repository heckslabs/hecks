require_relative "../../bluebook/expression/evaluator"

module Hecks
  module Fuzzing
    module Properties
      # Checks a replay's `history[:outbox_traces]` against the transactional outbox contract
      # (`Runtime::Outbox`): inline delivery, and no silent policy drops.
      #
      # A `saga:` row is exempt from the reaction_log check: `begin_saga` and `end_saga` have
      # ordinary no-op paths that log nothing, so a delivered saga row without one is fine.
      module Outbox
        # Every outbox row drained inline and no delivered policy row lacks its reaction.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each offending row
        def outbox_rows_match_reactions(history)
          bluebooks = history.fetch(:bluebooks, {})

          offenders = Array(history[:outbox_traces]).flat_map do |trace|
            trace[:rows].flat_map { |row| outbox_row_offenders(row, trace, bluebooks) }
          end

          offenders.empty? || offenders.join("; ")
        end

        # Offending messages for one row: zero or one, empty when the status names no check.
        def outbox_row_offenders(row, trace, bluebooks)
          on = row.dig(:event, :name)

          case row[:status]
          when "pending", "claimed"
            ["outbox row #{row[:delivery_id]} (#{row[:consumer]} on #{on}) never drained inline — status stayed " \
             "#{row[:status].inspect} though delivery is inline by contract (Runtime::Outbox's own header)"]
          when "failed"
            ["outbox row #{row[:delivery_id]} (#{row[:consumer]} on #{on}) failed to deliver: #{row[:error]} — " \
             "a domain refusal never reaches this far; a failed row names a defect in the relay's own consumer " \
             "resolution"]
          when "delivered"
            outbox_delivered_policy_offenders(row, on, trace, bluebooks)
          else
            []
          end
        end

        # Offending messages for a delivered `policy:` row that has no `reaction_log` entry.
        #
        # Legitimate only when the policy's `where` does not hold; a saga row gets no such check.
        def outbox_delivered_policy_offenders(row, on, trace, bluebooks)
          kind, fqn = row[:consumer].to_s.split(":", 2)
          return [] unless kind == "policy"

          home, name = fqn.to_s.split("::", 2)
          return [] if trace[:reactions].any? { |entry| entry[:policy] == name && entry[:on] == on }

          policy = bluebooks[home]&.policies&.find { |candidate| candidate.name == name }
          # Undeclared policy: inconclusive, not a mismatch.
          return [] unless policy
          # Fan-out counts belong to fanout_dispatches_once_per_matching_row.
          return [] if policy.fans_out?

          held = independently_re_evaluate_policy_where(policy, row[:event])
          # False or inconclusive (the where raised): never a mismatch.
          return [] if held != true

          ["outbox row #{row[:delivery_id]} (#{row[:consumer]} on #{on}) drained as delivered, but no matching " \
           "reaction_log entry exists and the policy's own where clause independently re-evaluates true — " \
           "PolicyInterpreter#deliver only ever returns nil (no reaction_log entry) when where does not hold"]
        end

        # Re-evaluates the policy's `where` against the row's recorded payload.
        #
        # Reproduces `PolicyInterpreter#where_holds?` rather than calling it, which would only
        # agree with itself. Rescues to nil: an unevaluable where is inconclusive, not false.
        #
        # @param policy [Bluebook::Policy] the policy whose `where` clause is re-evaluated
        # @param event [Hash] the outbox row's own recorded event, read for `:payload`
        # @return [Boolean, nil] whether `where` holds, or nil if it cannot be re-evaluated
        def independently_re_evaluate_policy_where(policy, event)
          return true if policy.where.to_s.empty?

          payload = (event[:payload] || {}).transform_keys(&:to_sym)
          Bluebook::Expression::Evaluator.call(policy.where, {}, payload)
        rescue StandardError
          nil
        end
      end
    end
  end
end
