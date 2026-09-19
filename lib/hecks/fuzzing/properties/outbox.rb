require_relative "../../bluebook/expression/evaluator"

module Hecks
  module Fuzzing
    module Properties
      # The transactional outbox's own contract (`Runtime::Outbox`, that
      # file's own header), held to the history a replay actually produced
      # rather than trusted. Two facts, each independently checkable from
      # `history[:outbox_traces]` (`Replay#call`'s own before/after
      # capture, one entry per step whose dispatch enqueued at least one
      # row):
      #
      # ## Check 1: delivery is inline by default
      #
      #   1. "delivery is inline by default" — a row this replay's own
      #      dispatch enqueued must not still be `pending`/`claimed` once
      #      that same call returns (nothing here ever simulates a
      #      crash), and must not be `failed` either — `deliver_row`'s
      #      own rescue only reaches `failed` for a genuine defect in the
      #      relay's own consumer resolution (a row naming a policy/
      #      process_manager `run_consumer`'s own independent registry
      #      lookup cannot find — `WiringError`), never an ordinary
      #      domain refusal (`PolicyInterpreter#deliver`/`SagaInterpreter#
      #      advance` both rescue those themselves, recording `delivered:
      #      false` on the reaction/saga log and letting `run_consumer`
      #      return normally). Both checked for every row, `saga:` and
      #      `policy:` alike.
      #
      # ## Check 2: a policy row's own where clause
      #
      #   2. A `policy:` row specifically — `PolicyInterpreter#deliver`
      #      returns `nil` (no `reaction_log` entry appended at all)
      #      exactly when its own `where` (or, for a fan-out policy, the
      #      same `where`, gating the whole `for_each`) does not hold;
      #      every other outcome (delivered, refused, a defect,
      #      reaction-depth-reached) is still a non-nil record `#react`
      #      appends. So a `delivered` policy row with no matching
      #      `reaction_log` entry is legitimate only when that policy's
      #      own `where`, independently re-evaluated here against the
      #      row's own recorded event, genuinely does not hold. A
      #      `for_each` policy's own fan-out correctness (how many rows
      #      it should have dispatched to) is `fanout_dispatches_once_
      #      per_matching_row`'s job, not this one's.
      #
      # ## Why a saga row is exempt from check 2
      #
      # A `saga:` row has no equivalent second check, deliberately —
      # `Fanout.sagas`' own `listens?` (starts_on/ends_on/handler_for
      # matching the event name alone) says nothing about whether a
      # correlation resolves or a live instance exists, and
      # `begin_saga`/`end_saga` (saga_interpreter.rb) both have silent,
      # perfectly ordinary no-op paths that append nothing to `saga_log`
      # — `begin_saga` when an instance under that correlation already
      # exists, `end_saga` when no live instance exists to end (an
      # `AccountOpened` fired by opening an account directly, bypassing
      # the onboarding flow whose `ends_on` names that same event,
      # reproduces this exactly: `Fanout.listens?` enqueues the row
      # because the event name matches `ends_on`, `end_saga` finds
      # nothing under that correlation to delete, and neither logs a
      # word). A `saga:` row draining to `delivered` with zero matching
      # `saga_log` entries is therefore not a finding — only check 1
      # applies to it.
      #
      # ## Not a grammar construct
      #
      # `FEATURE_COVERAGE`'s own `dry_runs_leave_no_trace` precedent: the
      # outbox is a runtime door (`Runtime::Outbox`), not a word a
      # bluebook declares, so there is no feature string here to claim.
      module Outbox
        # Checks every captured outbox row against `Runtime::Outbox`'s own contract
        # (see this module's own header for the two checks applied).
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true if every row in `history[:outbox_traces]`
        #   satisfies its contract; otherwise a message naming every offending row
        def outbox_rows_match_reactions(history)
          bluebooks = history.fetch(:bluebooks, {})

          offenders = Array(history[:outbox_traces]).flat_map do |trace|
            trace[:rows].flat_map { |row| outbox_row_offenders(row, trace, bluebooks) }
          end

          offenders.empty? || offenders.join("; ")
        end

        # Checks one outbox row against check 1 (and, when `delivered`, check 2).
        #
        # @param row [Hash] one outbox row, with at least `:delivery_id`, `:status`,
        #   `:event`, `:consumer`, `:error`
        # @param trace [Hash] the row's own `history[:outbox_traces]` entry, with
        #   `:verb`, `:rows`, `:reactions`, `:sagas`
        # @param bluebooks [Hash{String => Bluebook::Chapter}] every loaded domain,
        #   keyed by name (`history[:bluebooks]`)
        # @return [Array<String>] one message per contract violation found for
        #   `row`; empty when it satisfies its contract
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
        #
        # @param row [Hash] the delivered outbox row to check
        # @param on [String, nil] the event name the row's own `:event` carries
        # @param trace [Hash] the row's own `history[:outbox_traces]` entry
        # @param bluebooks [Hash{String => Bluebook::Chapter}] every loaded domain,
        #   keyed by name (`history[:bluebooks]`)
        # @return [Array<String>] one message if the row drained delivered with no
        #   matching reaction and its policy's own where clause re-evaluates true;
        #   empty otherwise, including when the check is inconclusive
        def outbox_delivered_policy_offenders(row, on, trace, bluebooks)
          kind, fqn = row[:consumer].to_s.split(":", 2)
          return [] unless kind == "policy"

          home, name = fqn.to_s.split("::", 2)
          return [] if trace[:reactions].any? { |entry| entry[:policy] == name && entry[:on] == on }

          policy = bluebooks[home]&.policies&.find { |candidate| candidate.name == name }
          # Nothing declared under this name — inconclusive, not a claimed mismatch.
          return [] unless policy
          # Fan-out row count is fanout_dispatches_once_per_matching_row's job.
          return [] if policy.fans_out?

          held = independently_re_evaluate_policy_where(policy, row[:event])
          # false, or inconclusive (the where itself raised) — never a claimed mismatch.
          return [] if held != true

          ["outbox row #{row[:delivery_id]} (#{row[:consumer]} on #{on}) drained as delivered, but no matching " \
           "reaction_log entry exists and the policy's own where clause independently re-evaluates true — " \
           "PolicyInterpreter#deliver only ever returns nil (no reaction_log entry) when where does not hold"]
        end

        # `PolicyInterpreter#where_holds?`'s own two branches, reproduced —
        # never calling that method again, which would only ever agree
        # with itself (the same rule `resolve_dispatch_binding`'s own
        # comment states). `Evaluator.call` (the raw-string entry, parsed
        # and cached — never `call_rule`, which needs the policy's own
        # build-time `where_rule` AST, an object this history has no
        # reason to carry) is the exact same call `Replay#fan_out_finding`
        # already makes for the identical fact one property over
        # (`policy.where.to_s.empty? || Evaluator.call(policy.where, {},
        # payload)`), reused rather than re-derived a second, slightly
        # different way. `rescue`d to `nil`, not `false`: a where clause
        # that cannot be re-evaluated from the row's own recorded payload
        # alone is inconclusive, not proof either way — the same "never a
        # claimed pass or a claimed mismatch from a resolution this replay
        # cannot actually reproduce" discipline `build_guard_check`'s own
        # rescue clause already follows.
        # @param policy [Bluebook::Policy] the policy whose `where` to re-evaluate
        # @param event [Hash] the recorded event the row fired from, with `:payload`
        # @return [Boolean, nil] true when `policy.where` is blank or evaluates
        #   true; false when it evaluates false; `nil` when it cannot be
        #   re-evaluated from `event`'s own recorded payload alone
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
