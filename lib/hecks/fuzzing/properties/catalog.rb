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
        :outbox_rows_match_reactions
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
        # No feature string exists for what this reads: an argument's own
        # `relationship` (Argument is a value object, outside the meta-domain
        # walk). Its declaration side, `Query#options`, is already claimed by
        # authorize_scopes_or_refuses.
        commands_respect_tenant_scope:                    []
      }.freeze

      # Features a replay could never observe violated, because construction
      # makes the violation impossible to produce — not untested, but
      # unfalsifiable. Each entry names the runtime path that guarantees it;
      # add one only after reading and confirming that path (mirrors the
      # discipline spec/fuzzing/meta_domain_coverage_spec.rb's KNOWN_GAPS demands
      # in the other direction).
      GUARANTEED_BY_CONSTRUCTION = {
        "Aggregate#attributes"    => "every field's pattern/closed-set/type passes through Value.build's one coercion " \
                                     "door (value/coercion.rb#check_patterns, value/admission.rb) before it can exist " \
                                     "— a stored value that violated its own declared shape was never producible to " \
                                     "begin with",
        "Aggregate#value_objects" => "the shape being coerced above — same door, same guarantee",
        # S17, ADR 0026 — saga_advances_follow_declared_handlers already walks
        # this list to find event_type/from_state/to_state; same door, same guarantee.
        "ProcessManager#handlers" => "saga_advances_follow_declared_handlers already walks this list to find " \
                                     "event_type/from_state/to_state — same door, same guarantee",
        "Aggregate#identified_by" => "CommandInterpreter's data-driven dispatch order refuses AlreadyExists " \
                                     "(command_interpreter.rb, command.creates?) for every creating command uniformly, " \
                                     "before a duplicate id can ever be stored — collision is refused at the door, not " \
                                     "produced and later caught",
        "Entity#identified_by"    => "EntityElement.check_entity_collision (runtime/entity_element.rb, moved there " \
                                     "BUG#145 so both call sites share it) checks Array(current) against every part " \
                                     "of the entity's own identity before an append can land — MutationApplier#" \
                                     "entity_element's aggregate-owned call (Workspace.boards, on both branches " \
                                     "identity arrives by: caller-supplied, or composite) AND EntityElement#" \
                                     "appended_to_element's entity-owned, nested-one-hop-further call (Board.cards — " \
                                     "unconditional, no auto-mint branch exists at that depth) — the same " \
                                     "AlreadyExists refusal Aggregate#identified_by gets above, one or two levels " \
                                     "down. Auto-minted (aggregate-owned) entities never reach the check " \
                                     "(current.size + 1 can't repeat unless something remove:s from the list between " \
                                     "mints, which no real domain does today — see the comment on #entity_element " \
                                     "itself)",
        "Command#attributes"      => "command arguments are coerced through the SAME Value.build door as any other " \
                                     "attribute — an accepted dispatch's own args already passed pattern/admits/invariant checks",
        "Command#emits"           => "CommandRules::Emission#emit iterates command.emits ITSELF to construct every " \
                                     "announced Event (command_rules/emission.rb) — there is no other path to emit, so " \
                                     "a command can never announce a name its own declaration doesn't list",
        "Query#attributes"        => "query arguments are coerced through the same Value.build door — same guarantee as " \
                                     "Command#attributes",
        "Query#returns"           => "every row a port answers is built as the returned value object by Value.build " \
                                     "(QueryInterpreter#shaped) before it enters the domain — an answer of any other " \
                                     "shape is refused, so none can be accepted",
        "Entity#attributes"       => "same coercion door, one level in — an entity's own attributes are Value-typed exactly " \
                                     "the way an aggregate's are",
        "ValueObject#attributes"  => "the shape Value.build enforces IS this declaration — the guarantee and the " \
                                     "feature are the same fact seen from two sides",
        "ValueObject#invariants"  => "run inside the SAME coercion call (coercion.rb, before construction returns) " \
                                     "that pattern-checks a VO's fields — a VO whose invariant did not hold could not " \
                                     "finish being built",
        "ValueObject#rows"        => "closed-set membership is checked in value/admission.rb, the second half of the same " \
                                     "one construction door",
        # S17, ADR 0026 — Member is a genuine entity, so this reads Member#pairs,
        # not Member#shape. ValueObject#members is the same fact ValueObject#rows
        # counts, seen from the other side.
        "ValueObject#members"     => "the members list IS what ValueObject#rows counts — same door, same guarantee",
        "Member#pairs"            => "one level into ValueObject#rows — same door"
      }.freeze
    end
  end
end
