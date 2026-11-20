# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # The census's 18 properties that re-run Ruby's interpreter or read Ruby-only traces
        # (classes (b) and (c), `docs/plans/simulation-tests-property-census.md`, Table 2), each
        # placed: rewritten as a metamorphic property, or not yet, with what it waits on.
        module Census
          # A census property and the metamorphic property that judges it on the kernel, with the
          # part of it the rewrite covers.
          REWRITES = {
            refusals_leave_no_trace:        { to:     :refusals_leave_the_store_identical,
                                              covers: "the instances part; journal, events, reactions, sagas " \
                                                      "and outbox are not on the serve session" },
            dry_runs_leave_no_trace:        { to: :dry_runs_change_nothing, covers: "all of it" },
            validation_agrees_with_dry_run: { to: :dry_run_agrees_with_dispatch, covers: "acceptance, not the facts" },
            replay_is_deterministic:        { to: :same_steps_same_history, covers: "all of it" }
          }.freeze

          # A census property with no serve form yet, and why.
          UNREWRITTEN = {
            query_answers_match_reference:                    "compares Ruby's two query interpreters; no kernel form",
            lifecycle_guard_and_given_violations_are_refused: "its refused half is refusals_leave_the_store_identical; " \
                                                              "the admitted twin, the same step on a store where the " \
                                                              "given holds, needs a generator that builds that store",
            mutations_match_recompute:                        "its serve form is append-then-remove identity, which needs " \
                                                              "inverse command pairs read from the IR",
            role_checks_agree_with_grants:                    "reads grants through a query; a serve session answers no " \
                                                              "query step",
            cursor_walk_yields_the_unpaged_rows:              "the kernel has no paged query",
            bulk_runs_match_hand_dispatch:                    "the kernel has no bulk run",
            set_transform_matches_row_by_row:                 "sqlite and postgres only; the kernel does no I/O (ADR 0012)",
            saga_advances_follow_declared_handlers:           "the serve session keeps its saga log and does not answer it",
            sagas_rehydrate_cleanly:                          "the serve session does not answer its saga instances",
            fanout_dispatches_once_per_matching_row:          "the serve session does not answer its reaction log",
            dispatch_binding_fidelity:                        "saga and policy dispatch bindings are not on the wire",
            outbox_rows_match_reactions:                      "the kernel has no outbox",
            policy_reactions_follow_declared_wiring:          "the serve session does not answer its reaction log",
            declared_undelivered_policies_stay_undelivered:   "the serve session does not answer its reaction log"
          }.freeze

          module_function

          # @return [Array<Symbol>] every census (b) and (c) property this module places
          def placed = REWRITES.keys + UNREWRITTEN.keys
        end
      end
    end
  end
end
