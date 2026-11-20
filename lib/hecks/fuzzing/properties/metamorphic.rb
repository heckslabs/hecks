# frozen_string_literal: true

require_relative "metamorphic/probe"
require_relative "metamorphic/faults"
require_relative "metamorphic/refusals_leave_the_store_identical"
require_relative "metamorphic/dry_runs_change_nothing"
require_relative "metamorphic/dry_run_agrees_with_dispatch"
require_relative "metamorphic/journal_replay_is_identity"
require_relative "metamorphic/snapshot_restore_is_identity"
require_relative "metamorphic/sessions_never_share_a_store"
require_relative "metamorphic/same_steps_same_history"
require_relative "metamorphic/census"

module Hecks
  module Fuzzing
    module Properties
      # Properties of the Rust kernel that need no second evaluator (layer 2 of
      # `docs/plans/simulation-tests.md`, slice 6): each relates two runs of the kernel through
      # nothing but its `--serve` host protocol (open, close, a verb, a dry run, `snapshot`,
      # `restore`, `instances`), so Ruby's interpreter judges none of them. The Ruby battery
      # (`Properties.check`) keeps running beside them until the last slice of the plan.
      module Metamorphic
        # Each property, by name, in the order {check} reports them.
        PROPERTIES = {
          refusals_leave_the_store_identical: RefusalsLeaveTheStoreIdentical,
          dry_runs_change_nothing:            DryRunsChangeNothing,
          dry_run_agrees_with_dispatch:       DryRunAgreesWithDispatch,
          journal_replay_is_identity:         JournalReplayIsIdentity,
          snapshot_restore_is_identity:       SnapshotRestoreIsIdentity,
          sessions_never_share_a_store:       SessionsNeverShareAStore,
          same_steps_same_history:            SameStepsSameHistory
        }.freeze

        # The property names.
        NAMES = PROPERTIES.keys.freeze

        module_function

        # Runs every property over one step list, each in sessions of its own.
        #
        # @param probe [Probe] a greeted serve connection
        # @param steps [Array<Hash>] a step list in the shape of `spec/corpus/*.json`; only its
        #   verb and dry-run steps are played
        # @return [Hash{Symbol => true, String}] each property name mapped to `true` (passed) or a
        #   message naming what broke
        def check(probe, steps)
          playable = Probe.playable(steps)
          PROPERTIES.transform_values { |property| property.call(probe, playable) }
        end
      end
    end
  end
end
