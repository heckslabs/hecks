require_relative "../../bluebook/expression/evaluator"

module Hecks
  module Fuzzing
    module Properties
      # THE TRANSACTIONAL OUTBOX'S OWN CONTRACT (`Runtime::Outbox`, that
      # file's own header), held to the history a replay actually produced
      # rather than trusted. Two facts, each independently checkable from
      # `history[:outbox_traces]` (`Replay#call`'s own before/after
      # capture, one entry per step whose dispatch enqueued at least one
      # row):
      #
      #   1. "DELIVERY IS INLINE BY DEFAULT" — a row THIS replay's own
      #      dispatch enqueued must not still be `pending`/`claimed` once
      #      that SAME call returns (nothing here ever simulates a
      #      crash), and must not be `failed` either — `deliver_row`'s
      #      own rescue only reaches `failed` for a genuine defect in the
      #      RELAY's own consumer resolution (a row naming a policy/
      #      process_manager `run_consumer`'s own independent registry
      #      lookup cannot find — `WiringError`), never an ordinary
      #      domain refusal (`PolicyInterpreter#deliver`/`SagaInterpreter#
      #      advance` both rescue those THEMSELVES, recording `delivered:
      #      false` on the reaction/saga log and letting `run_consumer`
      #      return normally). Both checked for every row, `saga:` and
      #      `policy:` alike.
      #
      #   2. A `policy:` ROW SPECIFICALLY — `PolicyInterpreter#deliver`
      #      returns `nil` (no `reaction_log` entry appended at all)
      #      EXACTLY when its own `where` (or, for a fan-out policy, the
      #      SAME `where`, gating the whole `for_each`) does not hold;
      #      every OTHER outcome (delivered, refused, a defect,
      #      reaction-depth-reached) is still a non-nil record `#react`
      #      appends. So a `delivered` policy row with NO matching
      #      `reaction_log` entry is legitimate ONLY when that policy's
      #      own `where`, independently RE-EVALUATED here against the
      #      row's own recorded event, genuinely does not hold. A
      #      `for_each` policy's own fan-out correctness (how MANY rows
      #      it should have dispatched to) is `fanout_dispatches_once_
      #      per_matching_row`'s job, not this one's.
      #
      # A `saga:` ROW HAS NO EQUIVALENT SECOND CHECK, DELIBERATELY — this
      # was the first shape this property shipped with, and it was WRONG,
      # caught live against `examples/banking` before this comment
      # existed: `Fanout.sagas`' own `listens?` (starts_on/ends_on/
      # handler_for matching the event NAME alone) says nothing about
      # whether a CORRELATION resolves or a LIVE INSTANCE exists, and
      # `begin_saga`/`end_saga` (saga_interpreter.rb) both have silent,
      # perfectly ordinary no-op paths that append NOTHING to `saga_log`
      # — `begin_saga` when an instance under that correlation already
      # exists, `end_saga` when NO live instance exists to end (an
      # `AccountOpened` fired by opening an account directly, bypassing
      # the onboarding flow whose `ends_on` names that same event,
      # reproduces this exactly: `Fanout.listens?` enqueues the row
      # because the event NAME matches `ends_on`, `end_saga` finds
      # nothing under that correlation to delete, and neither logs a
      # word). A `saga:` row draining to `delivered` with zero matching
      # `saga_log` entries is therefore NOT a finding — only check 1
      # applies to it.
      #
      # NOT A GRAMMAR CONSTRUCT — `FEATURE_COVERAGE`'s own `dry_runs_
      # leave_no_trace` precedent: the outbox is a runtime door
      # (`Runtime::Outbox`), not a word a bluebook declares, so there is
      # no feature string here to claim.
      module Outbox
        def outbox_rows_match_reactions(history)
          bluebooks = history.fetch(:bluebooks, {})

          offenders = Array(history[:outbox_traces]).flat_map do |trace|
            trace[:rows].flat_map { |row| outbox_row_offenders(row, trace, bluebooks) }
          end

          offenders.empty? || offenders.join("; ")
        end

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

        # See this file's own header for why a `saga:` row is exempt: its
        # own `listens?` gives no such guarantee, unlike a policy's single,
        # deterministic `where` gate.
        def outbox_delivered_policy_offenders(row, on, trace, bluebooks)
          kind, fqn = row[:consumer].to_s.split(":", 2)
          return [] unless kind == "policy"

          home, name = fqn.to_s.split("::", 2)
          return [] if trace[:reactions].any? { |entry| entry[:policy] == name && entry[:on] == on }

          policy = bluebooks[home]&.policies&.find { |candidate| candidate.name == name }
          return [] unless policy # nothing declared under this name — inconclusive, not a claimed mismatch
          return [] if policy.fans_out? # fan-out row count is fanout_dispatches_once_per_matching_row's job

          held = independently_re_evaluate_policy_where(policy, row[:event])
          return [] if held != true # false, or inconclusive (the where itself raised) — never a claimed mismatch

          ["outbox row #{row[:delivery_id]} (#{row[:consumer]} on #{on}) drained as delivered, but no matching " \
           "reaction_log entry exists and the policy's own where clause independently re-evaluates true — " \
           "PolicyInterpreter#deliver only ever returns nil (no reaction_log entry) when where does not hold"]
        end

        # `PolicyInterpreter#where_holds?`'s own two branches, reproduced —
        # never calling that method again, which would only ever agree
        # with itself (the same rule `resolve_dispatch_binding`'s own
        # comment states). `Evaluator.call` (the raw-string entry, parsed
        # and cached — never `call_rule`, which needs the policy's own
        # BUILD-TIME `where_rule` AST, an object this history has no
        # reason to carry) is the exact same call `Replay#fan_out_finding`
        # already makes for the identical fact one property over
        # (`policy.where.to_s.empty? || Evaluator.call(policy.where, {},
        # payload)`), reused rather than re-derived a second, slightly
        # different way. `rescue`d to `nil`, not `false`: a where clause
        # that cannot be re-evaluated from the row's own recorded payload
        # alone is INCONCLUSIVE, not proof either way — the same "never a
        # claimed pass or a claimed mismatch from a resolution this replay
        # cannot actually reproduce" discipline `build_guard_check`'s own
        # rescue clause already follows.
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
