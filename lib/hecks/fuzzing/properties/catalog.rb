module Hecks
  module Fuzzing
    module Properties
      # The standard battery, in the order `check` reports it.
      PROPERTY_NAMES = [
        :lifecycle_values_are_declared,
        :saga_advances_follow_declared_handlers,
        :query_answers_match_reference,
        :guard_refusals_are_declared,
        :sagas_rehydrate_cleanly,
        :fanout_dispatches_once_per_matching_row,
        :aggregation_matches_recompute,
        :stored_records_satisfy_declared_invariants,
        :group_by_matches_recompute,
        :paging_offset_partitions_correctly,
        :lifecycle_guard_and_given_violations_are_refused,
        :authorize_scopes_or_refuses,
        :commands_respect_tenant_scope,
        :dispatch_binding_fidelity,
        :mutations_match_recompute,
        :dry_runs_leave_no_trace,
        :corrections_reference_an_emitted_event,
        :outbox_rows_match_reactions,
        :policy_reactions_follow_declared_wiring,
        :declared_undelivered_policies_stay_undelivered,
        :references_resolve_to_earlier_records,
        :role_checks_agree_with_grants,
        :read_model_names_resolve_uniquely,
        :read_model_heads_compose_from_references
      ].freeze

      # Which language feature each property is answerable for — exhaustive of
      # what would go unchecked without it, not of everything its body touches.
      FEATURE_COVERAGE = {
        lifecycle_values_are_declared:                    %w[Aggregate#state_field Aggregate#state_start Aggregate#transitions
                                                             Entity#state_field Entity#state_start Entity#transitions],
        saga_advances_follow_declared_handlers:           %w[Handler#from_state Handler#to_state Handler#event_type],
        query_answers_match_reference:                    %w[Query#wheres Query#order_field Query#order_way Query#limit],
        paging_offset_partitions_correctly:               %w[Query#options],
        authorize_scopes_or_refuses:                      %w[Query#options],
        guard_refusals_are_declared:                      %w[Command#givens Command#ensures Command#needs],
        lifecycle_guard_and_given_violations_are_refused: %w[Command#from Aggregate#preconditions Entity#preconditions],
        # Dispatch#command_name/with_spec aren't claimable feature names — the
        # coverage walk only reaches one level of entity nesting and Dispatch
        # sits two deep — but this property still checks the real behavior
        # (dispatch_args) those names would have covered.
        dispatch_binding_fidelity:                        %w[Handler#dispatches Policy#with_spec],
        mutations_match_recompute:                        %w[Command#mutations],
        sagas_rehydrate_cleanly:                          %w[ProcessManager#states ProcessManager#correlates_by
                                                             ProcessManager#starts_on ProcessManager#ends_on],
        fanout_dispatches_once_per_matching_row:          %w[Policy#for_each Policy#where],
        aggregation_matches_recompute:                    %w[ReadModel#count ReadModel#median_field ReadModel#sum_field
                                                             ReadModel#avg_field ReadModel#min_field ReadModel#max_field
                                                             ReadModel#percentile_field ReadModel#percentile_at
                                                             ReadModel#any_field ReadModel#all_field],
        stored_records_satisfy_declared_invariants:       %w[Aggregate#invariants Entity#invariants],
        group_by_matches_recompute:                       %w[ReadModel#group_by],
        # A runtime door, not a grammar construct — `Dispatcher#dry_run?` is not
        # a word a bluebook declares. Listed empty rather than omitted, so every
        # property still names what it is answerable for.
        dry_runs_leave_no_trace:                          [],
        # Another runtime door, not a grammar construct — same reasoning as
        # dry_runs_leave_no_trace above.
        outbox_rows_match_reactions:                      [],
        # Reads command.mutations for :corrects ops — the same list
        # mutations_match_recompute reads, for a different question.
        corrections_reference_an_emitted_event:           %w[Command#mutations],
        # Reads each logged reaction back against the policy that produced it: the event it
        # answers, the trigger it builds, and the domain `across` sends it to. An `ask` closes
        # here too: boot binds it to the trigger it resolves to, which this reads as any other.
        policy_reactions_follow_declared_wiring:          %w[Policy#on_event Policy#trigger_command Policy#ask
                                                             Policy#target_domain],
        # model_check holds the static half of `expect_undelivered`; this is the runtime half.
        declared_undelivered_policies_stay_undelivered:   %w[Policy#expect_undelivered],
        # An accepted referencing command addressed a record an earlier event created.
        references_resolve_to_earlier_records:            %w[Command#references],
        # The grants read back through the verb the authorization provider declares in `provides`.
        role_checks_agree_with_grants:                    %w[Bluebook#provides],
        read_model_names_resolve_uniquely:                %w[ReadModel#query_name],
        # Each head's rows recomputed from the references; options apply to targeted heads only.
        read_model_heads_compose_from_references:         %w[ReadModel#reference_name ReadModel#reference_target
                                                             ReadModel#aggregate_heads ReadModel#options],
        # No feature string exists for what this reads: an argument's own
        # `relationship` (Argument is a value object, outside the meta-domain
        # walk). Its declaration side, `Query#options`, is already claimed by
        # authorize_scopes_or_refuses.
        commands_respect_tenant_scope:                    []
      }.freeze
    end
  end
end
