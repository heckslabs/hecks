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
require_relative "properties/corrections"
require_relative "properties/outbox"

module Hecks
  module Fuzzing
    # Declared properties, checked over a replayed history — the other
    # half of property-based testing the fuzzer was missing: it already
    # generates and (with bin/fuzz's shrinker) minimizes, but checked
    # nothing beyond "did the interpreter crash" and "did the replay
    # match the claim." A property here is a fact that should hold of
    # any history a valid domain produces, independent of which seed
    # produced it.
    #
    # ## Property shape
    #
    # Each property is `name => ->(history) { true/false, or a message
    # string naming what broke }` — a truthy return (including `true`)
    # is a pass; a String return is a failure, and the string is the
    # finding. `history` is Replay's return shape.
    #
    # ## Feature coverage
    #
    # Every property declares the language feature it covers, in
    # `FEATURE_COVERAGE` below — a "Construct#attribute" pair spelled
    # exactly as `Bluebook::MetaValidator.grammar_registry` names it,
    # the same meta-domain that judges every real bluebook (see that
    # module's own header: "the language IS the source"). That is the
    # link this file exists to make real: a construct the language
    # declares is a fact `spec/meta_domain_coverage_spec.rb` can
    # enumerate on its own, without anyone re-typing the list here —
    # so a new attribute added to `language/bluebook/*.bluebook` shows
    # up in that spec as unclaimed the moment it lands, not whenever
    # someone remembers to go looking. Claiming a feature here is a
    # deliberate act (a real property, checked at least once failing
    # and once passing — `spec/fuzzing/properties_spec.rb`'s own
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
      extend DryRuns
      extend InvariantsAndAggregation
      extend Corrections
      extend Outbox

      module_function

      # Which language feature each property is answerable for. Not
      # exhaustive of everything a property's body happens to touch —
      # `Command#attributes`, say, is exercised by nearly every property
      # here without being what any of them was written to guard — but
      # exhaustive of the feature that would go unchecked if this
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
        # Dispatch#command_name/Dispatch#with_spec are not claimable
        # feature names — META_DOMAIN_ALL_FEATURES only walks one level
        # of entity nesting (`agg.entities.flat_map`, meta_domain_
        # coverage_spec.rb), and Dispatch sits two deep (ProcessManager
        # -&gt; Handler -&gt; Dispatch), so those strings never exist there
        # to claim — a pre-existing meta-domain coverage-generation gap,
        # found here (their old META_DOMAIN_KNOWN_GAPS entries were
        # themselves already-orphaned strings no completeness check ever
        # verified, since KNOWN_GAPS has no "never lets a gap rot" check
        # the way FEATURE_COVERAGE/GUARANTEED_BY_CONSTRUCTION both do).
        # This property still closes the real behavior both would have
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
        group_by_matches_recompute:                       %w[ReadModel#group_by],
        # A runtime door, not a grammar construct — `Dispatcher#dry_run?`
        # is something an application asks of a booted domain, not a
        # word a bluebook can declare, so there is no feature string
        # for it to claim. Listed (empty) rather than omitted so the
        # discipline this table states — every property names what it
        # is answerable for — has no silent exception.
        dry_runs_leave_no_trace:                          [],
        # Another runtime door, not a grammar construct — same reasoning
        # as dry_runs_leave_no_trace right above: `Runtime::Outbox` is
        # something a persistence adapter provides underneath a booted
        # domain, never a word a bluebook declares.
        outbox_rows_match_reactions:                      [],
        # **The `corrects` mutation's own target** — this property reads
        # `command.mutations.select { op == :corrects }` and asks whether
        # the event each one names was ever actually emitted, so the
        # feature it answers for is the mutation list, the same one
        # `mutations_match_recompute` reads for a different question.
        # (Not `Command#references`: that field is the dangling-reference
        # question no property asks yet, and it stays a named gap.)
        corrections_reference_an_emitted_event:           %w[Command#mutations],
        # No feature string exists for what this one reads. It depends on
        # an argument's own `relationship` (which reference-typed argument
        # points at which aggregate) — but `Argument` is a value object,
        # and the meta-domain walk enumerates aggregate and entity fields
        # only, so no `Argument#…` name is claimable. The declaration side
        # it shares with queries, `authorize …, tenant:`, is
        # `Query#options`, already claimed by `authorize_scopes_or_refuses`;
        # claiming it twice would say this property covers a query
        # question it never asks. Listed (empty) rather than omitted, the
        # same discipline the two runtime doors above keep.
        commands_respect_tenant_scope:                    []
      }.freeze

      # Features a replay property could never catch violated, because the
      # runtime's own construction makes the violation impossible to
      # produce in the first place — not "untested," but unfalsifiable by
      # a history, the same class of guarantee this codebase already
      # states for identity ("nothing is minted" — command_interpreter.rb's
      # own header) and now generalises. Each entry names the one place in
      # the runtime that makes it true, universally, for every domain and
      # every adapter — never per-domain logic a future domain could
      # accidentally route around.
      #
      # The bluebook/hecksagon boundary is why this works: a bluebook
      # declares shape (attribute types, patterns, closed sets, VO
      # invariants — see docs/decisions/0009), and shape is enforced by
      # one coercion door every domain's every attribute passes through
      # (`Runtime::Value.build`, via value/coercion.rb + value/admission.rb)
      # regardless of which hecksagon later binds the aggregate to Memory,
      # Postgres, or anything else. A value that violated its own declared
      # pattern, invariant, or closed set could never be coerced, so it
      # could never be stored, so it could never appear in a replay's own
      # `:instances` to be caught violating it. Checking for it after the
      # fact would be watching for something the construction path already
      # made impossible.
      #
      # Not a place to hide a real gap — a feature belongs here only once
      # the specific enforcing code path has been read and confirmed, the
      # same discipline `spec/fuzzing/meta_domain_coverage_spec.rb` demands
      # of `KNOWN_GAPS` in the other direction. `Entity#identified_by`
      # illustrates the discipline: `command_interpreter.rb`'s
      # `AlreadyExists` refusal covers every creating aggregate command
      # uniformly, but nothing else on its own covers an entity's own
      # append — so this entry names the path that actually does,
      # `MutationApplier#check_entity_collision` (command_interpreter/
      # mutation_applier.rb), which runs unconditionally on both branches
      # an entity identity can arrive by (caller-supplied, or composite —
      # the two the auto-mint branch doesn't cover), the same way
      # `command_interpreter#hydrate`'s own check is unconditional for
      # every creating aggregate command. The collision this closes is
      # real, not hypothetical: SafeDepositBox's Visit/KeyIssuance entities
      # reproduce it, confirmed by spec/runtime/safe_deposit_box_spec.rb.
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
        # serialized as text. "ValueObject#members" is the same fact
        # "ValueObject#rows" already counts, seen from the other side — a
        # value object cannot declare admitted rows without a members list
        # to hold them, and vice versa.
        "ValueObject#members"     => "the members list IS what ValueObject#rows counts — same door, same guarantee",
        "Member#pairs"            => "one level into ValueObject#rows — same door"
      }.freeze

      # Runs the standard property battery over one replayed history —
      # everything except determinism, which needs to replay twice itself
      # and so takes the steps directly rather than a single history.
      #
      # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
      # @return [Hash{Symbol => true, String}] each property name mapped to `true`
      #   (passed) or a message string naming what broke
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
          commands_respect_tenant_scope:                    commands_respect_tenant_scope(history),
          dispatch_binding_fidelity:                        dispatch_binding_fidelity(history),
          mutations_match_recompute:                        mutations_match_recompute(history),
          dry_runs_leave_no_trace:                          dry_runs_leave_no_trace(history),
          corrections_reference_an_emitted_event:           corrections_reference_an_emitted_event(history),
          outbox_rows_match_reactions:                      outbox_rows_match_reactions(history) }
      end
    end
  end
end
