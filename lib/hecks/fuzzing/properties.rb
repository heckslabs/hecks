require "json"
require_relative "../bluebook/model_check"
require_relative "../bluebook/meta_validator"
require_relative "../ports/query/in_memory"
require_relative "../query_specification/field_path"
require_relative "../runtime/value"
require_relative "properties/lifecycle_and_replay"
require_relative "properties/querying"
require_relative "properties/guards"
require_relative "properties/dispatch_and_mutations"
require_relative "properties/invariants_and_aggregation"

module Hecks
  module Fuzzing
    # Declared properties, checked over a REPLAYED history — the other
    # half of property-based testing the fuzzer was missing: it already
    # generates and (with bin/fuzz's shrinker) minimizes, but checked
    # nothing beyond "did the interpreter crash" and "did the replay
    # match the claim." A property here is a fact that should hold of
    # ANY history a valid domain produces, independent of which seed
    # produced it.
    #
    # Each property is `name => ->(history) { true/false, or a message
    # string naming what broke }` — a truthy return (including `true`)
    # is a pass; a String return is a failure, and the string IS the
    # finding. `history` is Replay's return shape.
    #
    # EVERY PROPERTY DECLARES THE LANGUAGE FEATURE IT COVERS, in
    # `FEATURE_COVERAGE` below — a "Construct#attribute" pair spelled
    # exactly as `Bluebook::MetaValidator.grammar_registry` names it,
    # the SAME meta-domain that judges every real bluebook (see that
    # module's own header: "the language IS the source"). That is the
    # link this file exists to make real: a construct the language
    # declares is a fact `spec/meta_domain_coverage_spec.rb` can
    # enumerate on its own, without anyone re-typing the list here —
    # so a new attribute added to `language/bluebook/*.bluebook` shows
    # up in that spec as UNCLAIMED the moment it lands, not whenever
    # someone remembers to go looking. Claiming a feature here is a
    # deliberate act (a real property, checked at least once failing
    # AND once passing — `spec/fuzzing/properties_spec.rb`'s own
    # discipline) or an explicit, reasoned exemption in that same
    # spec — never silence.
    module Properties
      # Grouped by responsibility across properties/*.rb (lifecycle_and_
      # replay, querying, guards, dispatch_and_mutations, invariants_and_
      # aggregation) — `extend`ed here rather than `include`d, matching
      # `module_function` below: every property is reachable as
      # `Properties.foo(history)`, a module-level call with no instance in
      # play, the same relationship AggregateBuilder::Sealing's `include`
      # has to instance methods and BluebookBuilder::Validation's `extend`
      # has to `self.` methods — the same "one namespace, its methods,
      # filed across files by responsibility" pattern, `module_function`
      # already made this module's own particular shape.
      extend LifecycleAndReplay
      extend Querying
      extend Guards
      extend DispatchAndMutations
      extend InvariantsAndAggregation

      module_function

      # WHICH LANGUAGE FEATURE EACH PROPERTY IS ANSWERABLE FOR. Not
      # exhaustive of everything a property's body happens to touch —
      # `Command#attributes`, say, is exercised by nearly every property
      # here without being what any of them was WRITTEN to guard — but
      # exhaustive of the feature that would go UNCHECKED if this
      # property did not exist. That is the question the coverage gate
      # actually asks.
      FEATURE_COVERAGE = {
        lifecycle_values_are_declared:                    %w[Aggregate#state_field Aggregate#state_start Aggregate#transitions
                                                             Entity#state_field Entity#state_start Entity#transitions],
        saga_advances_follow_declared_handlers:           %w[Handler#from_state Handler#to_state Handler#event_type],
        query_answers_match_reference:                    %w[Query#wheres Query#order_field Query#order_way Query#limit],
        paging_offset_partitions_correctly:               %w[Query#options],
        authorize_scopes_or_refuses:                      %w[Query#options],
        guard_refusals_are_declared:                      %w[Command#givens Command#ensures],
        lifecycle_guard_and_given_violations_are_refused: %w[Command#from Aggregate#preconditions Entity#preconditions],
        # Dispatch#command_name/Dispatch#with_spec are NOT claimable
        # feature names — META_DOMAIN_ALL_FEATURES only walks ONE level
        # of entity nesting (`agg.entities.flat_map`, meta_domain_
        # coverage_spec.rb), and Dispatch sits TWO deep (ProcessManager
        # -&gt; Handler -&gt; Dispatch), so those strings never exist there
        # to claim — a pre-existing meta-domain coverage-generation gap,
        # found here (their old META_DOMAIN_KNOWN_GAPS entries were
        # themselves already-orphaned strings no completeness check ever
        # verified, since KNOWN_GAPS has no "never lets a gap rot" check
        # the way FEATURE_COVERAGE/GUARANTEED_BY_CONSTRUCTION both do).
        # This property still closes the REAL behavior both would have
        # named — a Dispatch's own command_name/with_spec are exactly
        # what dispatch_args resolves and this property checks — the
        # grammar just has no feature string for either one.
        dispatch_binding_fidelity:                        %w[Handler#dispatches Policy#with_spec],
        mutations_match_recompute:                        %w[Command#mutations],
        sagas_rehydrate_cleanly:                          %w[ProcessManager#states ProcessManager#correlates_by
                                                             ProcessManager#starts_on ProcessManager#ends_on],
        fanout_dispatches_once_per_matching_row:          %w[Policy#for_each Policy#where],
        aggregation_matches_recompute:                    %w[ReadModel#count ReadModel#median_field],
        stored_records_satisfy_declared_invariants:       %w[Aggregate#invariants Entity#invariants],
        group_by_matches_recompute:                       %w[ReadModel#group_by]
      }.freeze

      # FEATURES A REPLAY PROPERTY COULD NEVER CATCH VIOLATED, because the
      # RUNTIME'S OWN CONSTRUCTION makes the violation impossible to
      # produce in the first place — not "untested," but unfalsifiable by
      # a history, the same class of guarantee this codebase already
      # states for identity ("NOTHING IS MINTED" — command_interpreter.rb's
      # own header) and now generalises. Each entry names the ONE place in
      # the runtime that makes it true, universally, for every domain and
      # every adapter — never per-domain logic a future domain could
      # accidentally route around.
      #
      # THE BLUEBOOK/HECKSAGON BOUNDARY IS WHY THIS WORKS: a bluebook
      # declares SHAPE (attribute types, patterns, closed sets, VO
      # invariants — see docs/decisions/0009), and shape is enforced by
      # ONE coercion door every domain's every attribute passes through
      # (`Runtime::Value.build`, via value/coercion.rb + value/admission.rb)
      # regardless of which hecksagon later binds the aggregate to Memory,
      # Postgres, or anything else. A value that violated its own declared
      # pattern, invariant, or closed set could never be COERCED, so it
      # could never be STORED, so it could never appear in a replay's own
      # `:instances` to be caught violating it. Checking for it after the
      # fact would be watching for something the construction path already
      # made impossible.
      #
      # NOT a place to hide a real gap — a feature belongs here only once
      # the SPECIFIC enforcing code path has been read and confirmed, the
      # same discipline `spec/fuzzing/meta_domain_coverage_spec.rb` demands
      # of `KNOWN_GAPS` in the other direction. `Entity#identified_by` was
      # checked FOR this category once before and found NOT to qualify —
      # `command_interpreter.rb`'s `AlreadyExists` refusal was given to
      # every CREATING AGGREGATE command uniformly, and MutationApplier
      # (command_interpreter/mutation_applier.rb) had no matching check on
      # an entity's own append. It does now: #check_entity_collision runs
      # unconditionally on both branches an entity identity can arrive by
      # (caller-supplied, or composite — the two the auto-mint branch
      # doesn't cover), the same way command_interpreter#hydrate's own
      # check is unconditional for every creating aggregate command. Real,
      # confirmed live before the fix (SafeDepositBox's Visit/KeyIssuance —
      # see spec/runtime/safe_deposit_box_spec.rb).
      GUARANTEED_BY_CONSTRUCTION = {
        "Aggregate#attributes"    => "every field's pattern/closed-set/type passes through Value.build's one coercion " \
                                     "door (value/coercion.rb#check_patterns, value/admission.rb) before it can exist " \
                                     "— a stored value that violated its own declared shape was never producible to " \
                                     "begin with",
        "Aggregate#value_objects" => "the shape being coerced above — same door, same guarantee",
        # S17, ADR 0026 — the list `saga_advances_follow_declared_handlers`
        # (below) already walks to find each handler's own event_type/
        # from_state/to_state (the three it claims) — a property cannot
        # check a handler's own fields without iterating the list that
        # holds them, so the list itself is exercised by the same door.
        "ProcessManager#handlers" => "saga_advances_follow_declared_handlers already walks this list to find " \
                                     "event_type/from_state/to_state — same door, same guarantee",
        "Aggregate#identified_by" => "CommandInterpreter's data-driven dispatch order refuses AlreadyExists " \
                                     "(command_interpreter.rb, command.creates?) for every creating command uniformly, " \
                                     "before a duplicate id can ever be stored — collision is refused at the door, not " \
                                     "produced and later caught",
        "Entity#identified_by"    => "MutationApplier#check_entity_collision (command_interpreter/mutation_applier.rb) " \
                                     "checks Array(current) against every part of the entity's own identity before an " \
                                     "append can land, on both branches identity arrives by (caller-supplied, or " \
                                     "composite) — the same AlreadyExists refusal Aggregate#identified_by gets above, " \
                                     "one level down. Auto-minted entities never reach the check (current.size + 1 " \
                                     "can't repeat unless something remove:s from the list between mints, which no " \
                                     "real domain does today — see the comment on #entity_element itself)",
        "Command#attributes"      => "command arguments are coerced through the SAME Value.build door as any other " \
                                     "attribute — an accepted dispatch's own args already passed pattern/admits/invariant checks",
        "Command#emits"           => "CommandRules::Emission#emit iterates command.emits ITSELF to construct every " \
                                     "announced Event (command_rules/emission.rb) — there is no other path to emit, so " \
                                     "a command can never announce a name its own declaration doesn't list",
        "Query#attributes"        => "query arguments are coerced through the same Value.build door — same guarantee as " \
                                     "Command#attributes",
        "Entity#attributes"       => "same coercion door, one level in — an entity's own attributes are Value-typed exactly " \
                                     "the way an aggregate's are",
        "ValueObject#attributes"  => "the shape Value.build enforces IS this declaration — the guarantee and the " \
                                     "feature are the same fact seen from two sides",
        "ValueObject#invariants"  => "run inside the SAME coercion call (coercion.rb, before construction returns) " \
                                     "that pattern-checks a VO's fields — a VO whose invariant did not hold could not " \
                                     "finish being built",
        "ValueObject#rows"        => "closed-set membership is checked in value/admission.rb, the second half of the same " \
                                     "one construction door",
        # S17, ADR 0026 — Member is a genuine entity now (nested under
        # ValueObject), so this reads "Member#pairs", not "Member#shape" —
        # the free-text, un-parsed spelling a standalone root once needed
        # no longer exists at all, an entity's own element is never
        # serialized as text. "ValueObject#members" is the SAME fact
        # "ValueObject#rows" already counts, seen from the other side — a
        # value object cannot declare admitted rows without a members list
        # to hold them, and vice versa.
        "ValueObject#members"     => "the members list IS what ValueObject#rows counts — same door, same guarantee",
        "Member#pairs"            => "one level into ValueObject#rows — same door"
      }.freeze

      # THE STANDARD BATTERY, run over one replayed history — everything
      # except determinism, which needs to replay TWICE itself and so
      # takes the steps directly rather than a single history.
      def check(history)
        { lifecycle_values_are_declared:                    lifecycle_values_are_declared(history),
          saga_advances_follow_declared_handlers:           saga_advances_follow_declared_handlers(history),
          query_answers_match_reference:                    query_answers_match_reference(history),
          guard_refusals_are_declared:                      guard_refusals_are_declared(history),
          sagas_rehydrate_cleanly:                          sagas_rehydrate_cleanly(history),
          fanout_dispatches_once_per_matching_row:          fanout_dispatches_once_per_matching_row(history),
          aggregation_matches_recompute:                    aggregation_matches_recompute(history),
          stored_records_satisfy_declared_invariants:       stored_records_satisfy_declared_invariants(history),
          group_by_matches_recompute:                       group_by_matches_recompute(history),
          paging_offset_partitions_correctly:               paging_offset_partitions_correctly(history),
          lifecycle_guard_and_given_violations_are_refused: lifecycle_guard_and_given_violations_are_refused(history),
          authorize_scopes_or_refuses:                      authorize_scopes_or_refuses(history),
          dispatch_binding_fidelity:                        dispatch_binding_fidelity(history),
          mutations_match_recompute:                        mutations_match_recompute(history) }
      end
    end
  end
end
