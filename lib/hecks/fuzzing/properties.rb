require "json"
require_relative "../bluebook/model_check"
require_relative "../bluebook/meta_validator"
require_relative "../ports/query/in_memory"
require_relative "../query_specification/field_path"
require_relative "../runtime/value"

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
        "Aggregate#attributes"    => "every field's pattern/closed-set/type passes through Value.build's one coercion door " \
                                     "(value/coercion.rb#check_patterns, value/admission.rb) before it can exist — a stored value that violated " \
                                     "its own declared shape was never producible to begin with",
        "Aggregate#value_objects" => "the shape being coerced above — same door, same guarantee",
        # S17, ADR 0026 — the list `saga_advances_follow_declared_handlers`
        # (below) already walks to find each handler's own event_type/
        # from_state/to_state (the three it claims) — a property cannot
        # check a handler's own fields without iterating the list that
        # holds them, so the list itself is exercised by the same door.
        "ProcessManager#handlers" => "saga_advances_follow_declared_handlers already walks this list to find event_type/from_state/to_state — same door, same guarantee",
        "Aggregate#identified_by" => "CommandInterpreter's data-driven dispatch order refuses AlreadyExists " \
                                     "(command_interpreter.rb, command.creates?) for every creating command uniformly, before a duplicate id " \
                                     "can ever be stored — collision is refused at the door, not produced and later caught",
        "Entity#identified_by"    => "MutationApplier#check_entity_collision (command_interpreter/mutation_applier.rb) " \
                                     "checks Array(current) against every part of the entity's own identity before an append can land, on " \
                                     "both branches identity arrives by (caller-supplied, or composite) — the same AlreadyExists refusal " \
                                     "Aggregate#identified_by gets above, one level down. Auto-minted entities never reach the check " \
                                     "(current.size + 1 can't repeat unless something remove:s from the list between mints, which no real " \
                                     "domain does today — see the comment on #entity_element itself)",
        "Command#attributes"      => "command arguments are coerced through the SAME Value.build door as any other " \
                                     "attribute — an accepted dispatch's own args already passed pattern/admits/invariant checks",
        "Command#emits"           => "CommandRules::Emission#emit iterates command.emits ITSELF to construct every announced " \
                                     "Event (command_rules/emission.rb) — there is no other path to emit, so a command can never announce a " \
                                     "name its own declaration doesn't list",
        "Query#attributes"        => "query arguments are coerced through the same Value.build door — same guarantee as " \
                                     "Command#attributes",
        "Entity#attributes"       => "same coercion door, one level in — an entity's own attributes are Value-typed exactly " \
                                     "the way an aggregate's are",
        "ValueObject#attributes"  => "the shape Value.build enforces IS this declaration — the guarantee and the " \
                                     "feature are the same fact seen from two sides",
        "ValueObject#invariants"  => "run inside the SAME coercion call (coercion.rb, before construction returns) " \
                                     "that pattern-checks a VO's fields — a VO whose invariant did not hold could not finish being built",
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

      # Every lifecycle field a replay leaves an instance holding is one
      # of the aggregate's OWN declared states — the full set, not just
      # `Lifecycle#states`' default+targets (see ModelCheck.full_states'
      # own comment on that hole). The tie to M2 is direct: the model
      # checker proves which states a domain's OWN declarations can ever
      # produce ; this proves a REAL RUN never produced anything else —
      # a coercion bug, a stale string surviving a rename, a default
      # that drifted from the declared set, would all show up here as a
      # value nothing upstream would have predicted.
      def lifecycle_values_are_declared(history)
        bluebook = history.fetch(:bluebook)
        declared = {}
        bluebook.aggregates.each do |aggregate|
          declared[aggregate.hecks_name] = Bluebook::ModelCheck.full_states(aggregate.lifecycle) if aggregate.lifecycle
        end
        return true if declared.empty?

        offenders = history.fetch(:instances).filter_map do |key, state|
          aggregate_name = key.split("::").last.split("#").first
          states = declared[aggregate_name]
          next unless states

          lifecycle = bluebook.aggregate(aggregate_name).lifecycle
          value = state[lifecycle.field]
          next if value.nil? || states.include?(value.to_s)

          "#{key} holds #{lifecycle.field}=#{value.inspect}, which #{aggregate_name} never declares as a state"
        end

        offenders.empty? || offenders.join("; ")
      end

      # Every saga advance a replay actually logged moved along an edge
      # the process manager DECLARED — `(from, to)` pairs that appear in
      # `saga_log` with `advanced: true` must be a `(handler.from_state,
      # handler.to_state)` pair some handler on that PM declares
      # (compensation edges included ; a REFUSED-triggered advance is a
      # handler like any other). A saga that advanced along a pair no
      # handler names would mean the runtime moved state the language
      # never authorized — the same trust ModelCheck's static reachability
      # rests on, checked here against what a run actually did.
      def saga_advances_follow_declared_handlers(history)
        bluebook = history.fetch(:bluebook)
        edges = Hash.new { |h, k| h[k] = [] }
        bluebook.process_managers.each do |pm|
          pm.handlers.each { |handler| edges[pm.name] << [handler.from_state, handler.to_state] }
        end
        return true if edges.empty?

        offenders = history.fetch(:sagas).filter_map do |entry|
          next unless entry[:advanced]

          pair = [entry[:from], entry[:to]]
          next if edges[entry[:process_manager]].include?(pair)

          "#{entry[:process_manager]} advanced #{pair.inspect}, which no declared handler names"
        end

        offenders.empty? || offenders.join("; ")
      end

      # THE FOUNDATIONAL ONE. `Hecks::Runtime` mints nothing — every
      # identity is declared and derived, never invented (see
      # command_interpreter.rb's own "NOTHING IS MINTED" — a random hex,
      # a counter, anything not reproducible from the payload, was
      # refused out of the runtime specifically because it broke this).
      # So the SAME steps, replayed against a FRESH boot, must produce
      # BYTE-IDENTICAL events, refusals, and instances — any drift here
      # is nondeterminism the runtime promised not to have: a wall-clock
      # read that leaked into compared state, a Hash iteration order a
      # comparison depended on, anything. Two independent replays, not a
      # cached one compared to itself, so a bug that corrupts the FIRST
      # run's own bookkeeping cannot pass by agreeing with itself.
      def replay_is_deterministic(domain_path, steps)
        first  = Replay.call(domain_path, steps)
        second = Replay.call(domain_path, steps)

        comparable = ->(history) { history.reject { |key, _| key == :bluebook || key == :bluebooks } }
        return true if comparable.call(first) == comparable.call(second)

        "two replays of the same #{steps.length} steps produced different histories"
      end

      # THE QUERY ORACLE — differential testing within the one runtime,
      # the shape the retired cross-runtime harness should always have
      # been. Every generated ask was answered twice at the same instant
      # (Replay records both): once through whatever the aggregate is
      # actually bound to (Memory's native hook is Ports::Query::InMemory;
      # a SQL binding would compile it), once through the reference
      # interpreter's own evaluation. The two are separate, live
      # implementations of the same comparator vocabulary, and they have
      # drifted before — an adapter that ACCEPTS what the reference says
      # matches nothing, or orders what it refuses to order, shows up
      # here as a finding no self-referential adapter spec could see.
      def query_answers_match_reference(history)
        offenders = history.fetch(:queries).filter_map do |asked|
          next if asked[:error] || asked[:reference_rows].nil?
          next if asked[:rows] == asked[:reference_rows]

          "#{asked[:query]} #{asked[:args].inspect} answered #{asked[:rows].inspect} " \
            "natively but #{asked[:reference_rows].inspect} through the reference interpreter"
        end

        offenders.empty? || offenders.join("; ")
      end

      # THE SAME "TWO ENGINES, COMPARED" SHAPE query_answers_match_reference
      # already uses, aimed squarely at Query#options' offset/limit pair —
      # but recomputed from history[:instances] directly, a THIRD,
      # independent computation, rather than comparing QueryInterpreter's
      # own native and reference paths against each other (which could
      # share the identical bug neither implementation happened to hit —
      # see #4's own fix, which touched BOTH #interpret and
      # #reference_interpret at once). `order_by` declared alongside
      # `offset` or `limit` names a genuinely paged query. Ports::Query::
      # Ordering.apply is the SAME engine QueryInterpreter#ordered calls,
      # reused here rather than re-derived, so this oracle cannot drift
      # from what "in order" means without the interpreter drifting the
      # identical way — only the offset-then-limit .drop/.first slice
      # (#4's own fix) is independently reproduced, in plain Ruby.
      #
      # Real target: ATMCard.ByFee (`limit 3; offset 1`).
      def paging_offset_partitions_correctly(history)
        bluebooks = history.fetch(:bluebooks)

        offenders = history.fetch(:queries).filter_map do |asked|
          next if asked[:error] || !asked[:query].is_a?(String) || !asked[:query].include?("::")

          declared = query_for_verb(bluebooks, asked[:query])
          next unless declared && declared.order_by && (declared.offset || declared.limit)

          domain, aggregate_name, = Naming.split_verb(asked[:query])
          args = asked[:args] || {}
          rows = query_eligible_rows(asked.fetch(:instances_at), domain, aggregate_name, declared.wheres, args)
          ordered = Ports::Query::Ordering.apply(
            rows, declared.order_by, declared.null_semantics, identity: ->(row) { row[:id].to_s }
          ) { |row| Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, declared.order_by.field)) }

          skipped  = declared.offset ? ordered.drop(resolve_paging_value(declared.offset.value, args).to_i) : ordered
          expected = declared.limit ? skipped.first(resolve_paging_value(declared.limit.value, args).to_i) : skipped
          actual   = asked[:rows]
          next if actual == expected

          "#{asked[:query]} #{args.inspect} answered #{actual.inspect}, but independently recomputing " \
            "order/offset/limit from #{rows.length} eligible row(s) gives #{expected.inspect}"
        end

        offenders.empty? || offenders.join("; ")
      end

      # THE DECLARED Query ITSELF, resolved from a replayed verb — the
      # same shape #command_for_verb resolves a command by, one
      # construct over. Entity-level queries (a dotted query_path) are
      # out of scope here — paging on an entity's own list has no real
      # corpus site yet, and the "one many-side head, one aggregate,
      # no FK-join" shape #query_eligible_rows assumes doesn't hold for
      # one.
      def query_for_verb(bluebooks, verb)
        domain, aggregate_name, query_path = Naming.split_verb(verb)
        return nil unless query_path && !query_path.include?(".")

        bluebook  = bluebooks[domain]
        aggregate = bluebook&.aggregate(aggregate_name)
        aggregate&.query(query_path)
      end

      # A QUERY'S OWN ROWS — unlike #eligible_rows (a ReadModel's
      # reduced/grouped many-side head, possibly FK-joined against a
      # root), a Query always asks about its OWN owning aggregate
      # directly ; no join, no reference_target. `id:` merged in the
      # same way #eligible_rows' own rows are, since a stable sort
      # (Ordering.apply's own `identity:`) and the real answer's own
      # `record.state.merge(id: record.id)` both need it.
      def query_eligible_rows(instances, domain, aggregate_name, wheres, args)
        prefix = "#{domain}::#{aggregate_name}#"
        instances.filter_map do |key, state|
          next unless key.start_with?(prefix)

          row = state.merge(id: key.split("#").last)
          next unless wheres.all? do |clause|
            held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, clause.field))
            Ports::Query::InMemory.holds?(clause, held, args)
          end

          row
        end
      end

      # `QueryInterpreter#resolve_query_value`, reproduced: a declared
      # limit/offset is either a literal or a Symbol naming an argument
      # the caller supplied.
      def resolve_paging_value(value, args)
        value.is_a?(Symbol) ? args[value] : value
      end

      # `Query#options`' OTHER HALF — TenantScope.apply's own contract
      # (tenant_scope.rb), independently restated as a property rather
      # than exercised only through whatever the generator happens to
      # try. NOT closed by the generator here on purpose: SafeDepositBox.
      # Rented — the only real corpus query declaring `authorize` at
      # all — declares ZERO attributes of its own, so StepBuilder#args_for
      # always hands it `{}` and TenantScope.apply refuses every
      # generated attempt, unconditionally (confirmed: no successful ask
      # against an authorize-bearing query reaches this property via the
      # standard battery today). Extending the generator to invent a
      # `tenant:` value ran into a separate, real finding along the way —
      # SafeDepositBox is COMPOSITE-identified (`identified_by` is nil
      # for it — Runtime::Identified#derive_identity), so the generator's
      # existing `known_ids` pool (keyed by `aggregate.identified_by ||
      # "id"`) tracks a stray, never-real scalar for it rather than its
      # true `branch_code`+`box_number` pair — a second, narrower
      # generator gap this property does not attempt to fix, since fixing
      # it well enough to trust a generated `tenant:` value would be the
      # heavier, "benefits every future property" path the plan itself
      # names as the alternative. Hand-built fixtures close the real
      # claim directly instead: faster, narrower, and correct either way,
      # since TenantScope.apply's contract is identical regardless of
      # where a `tenant:` arg came from.
      #
      # Two claims, matching TenantScope.apply's own two branches: every
      # SUCCESSFUL answer's own tenant field agrees with the tenant arg
      # given (the WhereClause TenantScope injects is a Symbol reference
      # into args, resolved dynamically — this checks the OUTCOME, not
      # re-deriving that resolution) ; every ask MISSING a required
      # tenant: refuses with the declared wording, never succeeds. A
      # refusal for an unrelated reason with the tenant arg present is
      # not this property's claim either way — skipped, not graded.
      def authorize_scopes_or_refuses(history)
        bluebooks = history.fetch(:bluebooks)

        offenders = history.fetch(:queries).filter_map do |asked|
          next unless asked[:query].is_a?(String) && asked[:query].include?("::")

          declared = query_for_verb(bluebooks, asked[:query])
          tenant = declared&.authorization&.tenant&.to_sym
          next unless tenant

          args = asked[:args] || {}
          tenant_given = args.key?(tenant)

          if asked[:error]
            next if tenant_given
            next if asked[:error].to_s.include?("declares authorize with tenant: #{tenant}")

            "#{asked[:query]} #{args.inspect} refused with no #{tenant}: given, but not with the declared " \
              "tenant_required wording (#{asked[:error]})"
          elsif !tenant_given
            "#{asked[:query]} #{args.inspect} answered successfully with no #{tenant}: given, but #{declared.name} " \
              "declares authorize with tenant: #{tenant}"
          else
            wanted = args[tenant].to_s
            mismatched = asked[:rows].find do |row|
              Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, tenant)).to_s != wanted
            end
            next unless mismatched

            "#{asked[:query]} #{args.inspect} answered a row whose #{tenant} disagrees with the given " \
              "#{wanted.inspect}: #{mismatched.inspect}"
          end
        end

        offenders.empty? || offenders.join("; ")
      end

      # EVERY GIVEN/ENSURES REFUSAL A RUN ACTUALLY RAISED NAMES A RULE
      # THE COMMAND ACTUALLY DECLARES. `GivenNotMet`/`EnsuresNotMet` both
      # quote their guard's own `description` verbatim
      # (command_rules/admissibility.rb: `"#{command.hecks_name} refused
      # — #{given.description}"`) — the SAME text `behavior.bluebook`'s
      # own `Rule`/Command.Ensure hold as `Rule#description`, so a
      # refusal whose quoted text is not among the refusing command's
      # OWN `guard_descriptions` (Behaviour::Command, both givens and
      # ensures) is either a stale message surviving a renamed rule, a
      # rule firing against the wrong command's own guard set, or the
      # wording drifting out from under the declaration it is supposed
      # to quote — banking's own 128 status givens (customer/account
      # guards, some through a cross-aggregate dereference) are exactly
      # the surface this exists to hold to its word.
      #
      # `kind:` is what tells a guard refusal apart from the FOUR other
      # `RefusalWording` templates sharing the identical "X refused — Y"
      # shape (LifecycleRefused/transition_blocked, both TypeMismatch
      # object-reference templates, Unauthorized/role_mismatch) — see
      # Replay's own comment at the refusal rescue site. Pattern-matching
      # the string alone would confuse a guard's own wording with any of
      # those; the raised class does not.
      GUARD_REFUSAL_KINDS = %w[Hecks::Runtime::GivenNotMet Hecks::Runtime::EnsuresNotMet].freeze

      def guard_refusals_are_declared(history)
        bluebooks = history.fetch(:bluebooks)

        offenders = history.fetch(:refusals).filter_map do |refusal|
          next unless GUARD_REFUSAL_KINDS.include?(refusal[:kind])

          match = refusal[:error].to_s.match(/\A(.+) refused — (.+)\z/)
          next "#{refusal[:verb]} raised #{refusal[:kind]} with unparseable message #{refusal[:error].inspect}" unless match

          command = command_for_verb(bluebooks, refusal[:verb])
          next "#{refusal[:verb]} raised #{refusal[:kind]}, but no declared command resolves that verb" unless command

          declared = effective_guard_descriptions(bluebooks, refusal[:verb], command)
          next if declared.include?(match[2])

          "#{refusal[:verb]} refused — #{match[2].inspect} — but #{command.hecks_name} declares no given " \
            "or ensures with that description (it declares #{declared.inspect})"
        end

        offenders.empty? || offenders.join("; ")
      end

      # A DECLARED PROCESS MANAGER'S OWN COMMAND — `command.hecks_name`,
      # or an entity's own if the verb's second component is itself
      # dotted (`Aggregate.Entity.Command`, the same two shapes
      # `Dispatcher#dispatch` itself branches on). Shared by the guard
      # property above and available for anything else that needs to go
      # from a replayed verb back to its declaration.
      #
      # RESOLVED AGAINST `bluebooks` (the FULL map, `history[:bluebooks]`
      # — every loaded domain, keyed by name), never a single assumed
      # bluebook: a verb names its OWN domain (`Naming.split_verb`'s
      # first element), and that domain is not always the one Replay
      # happens to expose as `history[:bluebook]`. A fuzz run against
      # `lib/hecks/grammar` (Expression + Translation, in load
      # order) found this the hard way — every `Translation::Map.Seal`
      # refusal read as "no declared command resolves that verb" purely
      # because `history[:bluebook]` was Expression, not Translation; the
      # refusal was real, this property's own domain resolution was not.
      # A DELEGATING DOOR REFUSES WITH ITS TARGET'S OWN WORDS. `delegates_to`
      # (CommandBuilder#delegates_to_impl) hands the whole dispatch to one
      # entity command, and that command's given is what refuses — raised
      # back through the door, in the door's name (chess: `Game.MoveKnight
      # refused — "it is that color's turn"`, a given Knight.Move declares
      # and MoveKnight, a pure passthrough, never could). Read the door's
      # own guards first, then every delegation target's; an offence is
      # only a description NEITHER declares. Found live mining chess's
      # history: every refused move through a door read as undeclared.
      def effective_guard_descriptions(bluebooks, verb, command)
        own = command.guard_descriptions
        delegated = command.mutations.select { |m| m.op == :delegate }.flat_map do |delegation|
          domain, aggregate_name, = Naming.split_verb(verb)
          target = command_for_verb(bluebooks, "#{domain}::#{aggregate_name}.#{delegation.target}")
          target ? target.guard_descriptions : []
        end
        own + delegated
      end

      def command_for_verb(bluebooks, verb)
        domain, aggregate_name, command_path = Naming.split_verb(verb)
        return nil unless command_path

        bluebook = bluebooks[domain]
        return nil unless bluebook

        aggregate = bluebook.aggregate(aggregate_name)
        return nil unless aggregate

        if command_path.include?(".")
          entity_name, sub = command_path.split(".", 2)
          entity = aggregate.entities.find { |e| e.hecks_name == entity_name }
          entity&.command(sub)
        else
          aggregate.command(command_path)
        end
      end

      # `guard_refusals_are_declared`'s OWN OPPOSITE DIRECTION. That
      # property is passive and one-directional — for a refusal that
      # ALREADY HAPPENED, is the quoted text real declared text? It says
      # nothing about a guard that should have refused and silently did
      # not — a call site that stopped calling enforce_givens/enforce_
      # lifecycle_guard would never appear in history[:refusals] at all,
      # invisible to that property by construction.
      #
      # This one calls Admissibility#enforce_givens (which itself folds
      # in #enforce_lifecycle_guard whenever `declaring:` is passed)
      # DIRECTLY, against Replay's own pre-dispatch snapshot
      # (history[:guard_checks], one bounded, additive extension — see
      # that file's own comment at the capture site) — an independent
      # recomputation, not grading production against itself, the same
      # "two engines, compared" shape query_answers_match_reference and
      # the fan-out oracle already establish. `recomputed_refused`
      # (Replay's own call, made live, before this step's real dispatch
      # could mutate anything a cross-aggregate given dereferences) is
      # compared against `actual_refused` (GivenNotMet/LifecycleRefused
      # specifically — Replay's own comment on GUARD_REFUSAL_CLASSES
      # explains why ANY other refusal class, or an outright success,
      # both count as "the guard did not fire," since enforce_givens
      # runs FIRST in DISPATCH_ORDER).
      #
      # Aggregate#preconditions closes for free alongside this — a
      # no-block `given` reference (CommandBuilder#given) pushes the
      # SAME Given struct object `enforce_givens` already iterates
      # command.givens for, so there is no separate runtime path a
      # property could exercise beyond what this already reaches.
      # Entity#preconditions closes the identical way, one level down
      # (ADR 0028) — a piece's own bare `given` reference pushes the
      # SAME Given struct onto ITS OWN referencing command's givens,
      # so LedgerEntry's own Amend/Reverse (banking) already exercise
      # this through the exact mechanism above, no separate path.
      #
      # Real targets: Account.Debit/CloseAccount (`from:` guards),
      # Credit/Debit (the named-once `given("customer is active")`
      # precondition) — FreezeAccount deliberately references the
      # DIFFERENT named precondition `"customer is not closed"` instead
      # (a suspended customer must still be freezable), so it is not a
      # `"customer is active"` example, just the same MECHANISM.
      def lifecycle_guard_and_given_violations_are_refused(history)
        offenders = history.fetch(:guard_checks).filter_map do |check|
          next if check[:recomputed_refused] == check[:actual_refused]

          "#{check[:verb]} — independently recomputing enforce_givens/enforce_lifecycle_guard against the " \
            "pre-dispatch state says #{check[:recomputed_refused] ? "refused (#{check[:recomputed_kind]})" : 'admitted'}, " \
            "but the real dispatch #{check[:actual_refused] ? "refused (#{check[:actual_kind]})" : 'admitted it'}"
        end

        offenders.empty? || offenders.join("; ")
      end

      # Closes Handler#dispatches and — the same shape, one construct
      # over — Policy#with_spec (Dispatch#command_name/Dispatch#with_spec
      # are not claimable feature strings at all — see FEATURE_COVERAGE's
      # own comment on this entry). history[:saga_dispatches]/[:policy_dispatches]
      # (Registry#saga_dispatch_log/#policy_dispatch_log — additive,
      # Ruby-only, NEVER touching saga_log/reaction_log, the byte-for-
      # byte shape spec/rust_conformance_spec.rb holds Rust to) each
      # carry the RAW inputs a dispatch's own args were resolved from,
      # captured live at the moment the resolution actually ran — a
      # saga's own memory keeps changing across a run, so re-deriving
      # from history[:saga_instances]'s FINAL memory (the only other
      # place it would be visible) would grade the wrong moment,
      # lifecycle_guard_and_given_violations_are_refused's own false
      # positive one item earlier, in a different shape.
      #
      # #resolve_dispatch_binding/#resolve_trigger_binding are SEPARATE,
      # independently-written re-derivations of SagaInterpreter#
      # dispatch_args/PolicyInterpreter#trigger_args's own resolution —
      # never calling either method again, which would only ever agree
      # with itself. Exactly the class of bug this closes: "a wrong
      # argument binding on a fan-out dispatch that produces a perfectly
      # normal-looking log entry (`delivered: true`) and would only ever
      # surface as a downstream assertion failure, if it surfaces at
      # all" — PR #325's own defect class, one level over.
      #
      # Real targets: Settlement (mixed literal/correlation-head/event-
      # payload/memory-fallback bindings across three legs, plus a
      # compensation leg that deliberately omits `reference:`, a field
      # the forward Credit leg carries), ExternalSettlement, Onboarding
      # (no compensation leg, by design — nothing to check there beyond
      # the forward leg's own event-payload binding).
      def dispatch_binding_fidelity(history)
        saga_offenders = history.fetch(:saga_dispatches, []).filter_map do |entry|
          expected = resolve_dispatch_binding(entry)
          next if expected == entry[:args]

          "#{entry[:process_manager]}##{entry[:instance]} dispatching #{entry[:dispatch]} on #{entry[:on]} — " \
            "bound #{entry[:args].inspect}, but independently re-deriving with_spec's own resolution gives " \
            "#{expected.inspect}"
        end

        policy_offenders = history.fetch(:policy_dispatches, []).filter_map do |entry|
          expected = resolve_trigger_binding(entry)
          next if expected == entry[:args]

          "#{entry[:policy]} on #{entry[:on]} — bound #{entry[:args].inspect}, but independently re-deriving " \
            "with_spec's own resolution gives #{expected.inspect}"
        end

        offenders = saga_offenders + policy_offenders
        offenders.empty? || offenders.join("; ")
      end

      # SagaInterpreter#dispatch_args's own 4-branch resolution,
      # reproduced independently: a literal, the correlation key itself,
      # the CURRENT triggering event's own payload, or — the fallback —
      # the saga's own carried memory (seeded from the STARTING event's
      # payload, at begin_saga).
      def resolve_dispatch_binding(entry)
        entry[:with_spec].to_h do |key, value|
          resolved = if !value.is_a?(Symbol) then value
                     elsif value == entry[:correlation_head] then entry[:instance]
                     elsif entry[:event_payload].key?(value) then entry[:event_payload][value]
                     else entry[:memory][value]
                     end
          [key.to_sym, Runtime::Value.materialize(resolved)]
        end
      end

      # PolicyInterpreter#trigger_args's own 2-branch resolution — a
      # policy holds no correlation and no memory, so `payload` (the
      # triggering event's own payload, already merged with a fan-out
      # row's id when there is one) is the WHOLE source.
      def resolve_trigger_binding(entry)
        entry[:with_spec].to_h do |key, value|
          resolved = value.is_a?(Symbol) ? entry[:payload][value] : value
          [key.to_sym, Runtime::Value.materialize(resolved)]
        end
      end

      # Closes Command#mutations — the last of the five, and the
      # largest: no real corpus entity anywhere uses `append`/`remove`/
      # `multiply`/`clamp` (every real aggregate-owned mutation is
      # aggregate-scoped — Account.Credit's :ledger, LogVisit's
      # :visits); the only entity-owned use of these four ops in the
      # whole repository is spec/fixtures/entity_list_mutations, now a
      # real, bootable, Memory-default domain (no .hecksagon needed at
      # all — a domain with none boots every aggregate against Memory
      # by construction, confirmed live) rather than the raw-Kernel.
      # load-only fixture it was.
      #
      # `history[:mutation_traces]` (Replay's own bounded, additive
      # extension — see #build_mutation_trace's own comment) carries a
      # per-step before/after snapshot of the ENTITY ELEMENT an
      # entity-dispatched command's own mutations acted on, materialized
      # to plain data, plus the step's own raw args — the delta
      # `aggregation_matches_recompute` never had to ask for, because
      # count/median are pure functions of FINAL state and a mutation
      # is not (the same "captured live, not re-derived from final
      # state" lesson item 8's own saga_dispatch_log already learned).
      #
      # #recompute_append/#recompute_remove/#recompute_multiply/
      # #recompute_clamp are SEPARATE, independently-written
      # reproductions of MutationApplier#appended/#removed and
      # CommandRules::Arithmetic#multiply/#clamp — never calling either
      # again, which would only ever agree with itself. `:set`/
      # `:increment`/`:decrement` are out of scope on purpose (the four
      # "vendored, not yet upstream" ops this item exists for); a
      # command mixing them with a recomputable op still gets the
      # recomputable one checked.
      #
      # `:unrecomputable` (never compared, never a finding) covers the
      # generator's own deliberate arg-malforming (`StepBuilder#malform`)
      # landing a non-Numeric amount/non-2-element bounds where
      # multiply/clamp need one — the SAME shape `guard_check`'s own
      # AbsentArgument false positive taught: a step whose raw material
      # doesn't fit the op's own contract is inconclusive, not a claimed
      # mismatch.
      RECOMPUTABLE_MUTATION_OPS = %i[append remove multiply clamp].freeze

      def mutations_match_recompute(history)
        bluebooks = history.fetch(:bluebooks)

        offenders = history.fetch(:mutation_traces, []).flat_map do |entry|
          next [] unless entry[:after]

          command = command_for_verb(bluebooks, entry[:verb])
          next [] unless command

          command.mutations.select { |m| RECOMPUTABLE_MUTATION_OPS.include?(m.op) }.filter_map do |mutation|
            expected = recompute_mutation(mutation, entry[:before][mutation.target], entry[:args], entry[:before])
            next if expected == :unrecomputable

            actual = entry[:after][mutation.target]
            next if symbolize_deep(expected) == symbolize_deep(actual)

            "#{entry[:verb]} — #{mutation.op} on #{mutation.target} — recomputing independently gives " \
              "#{expected.inspect}, but the real dispatch left #{actual.inspect}"
          end
        end

        offenders.empty? || offenders.join("; ")
      end

      def recompute_mutation(mutation, current, args, before_scope)
        case mutation.op
        when :append   then recompute_append(current, mutation.source, before_scope, args)
        when :remove   then recompute_remove(current, mutation.source, args)
        when :multiply then recompute_multiply(current, resolve_mutation_source(mutation.source, args))
        when :clamp    then recompute_clamp(current, mutation.source)
        end
      end

      # `MutationApplier#appended`'s own value-object branch (never the
      # entity_element branch — see #build_mutation_trace's own comment
      # on why an entity-dispatched command's own mutations never reach
      # it), reproduced: the field map resolved the SAME two-tier way
      # (`MutationApplier#resolve_append_source` — a caller-supplied
      # arg, or the entity's own current field), then appended.
      def recompute_append(current, source_map, before_scope, args)
        fields = source_map.transform_values { |source| resolve_mutation_append_field(source, before_scope, args) }
        Array(current) + [symbolize_deep(fields)]
      end

      def resolve_mutation_append_field(source, before_scope, args)
        return source unless source.is_a?(Symbol)
        return args[source] if args.key?(source)

        before_scope[source]
      end

      # `MutationApplier#removed`'s own value-equality match, reproduced.
      def recompute_remove(current, source, args)
        target = symbolize_deep(resolve_mutation_source(source, args))
        Array(current).reject { |element| symbolize_deep(element) == target }
      end

      # `CommandRules::Arithmetic#multiply`'s own two branches,
      # reproduced on plain materialized data instead of a real Value:
      # a single-numeric-field Hash (the VO-typed case — ListCount, one
      # Integer field) scales that field ; a bare Numeric scales itself.
      # `current ||= 0` — the SAME phantom-field fallback #multiply
      # itself already gives (unaffected by this session's #clamp fix,
      # since #multiply never needed one).
      def recompute_multiply(current, amount)
        return :unrecomputable unless amount.is_a?(Numeric)

        current ||= 0
        if current.is_a?(Hash)
          field = current.keys.find { |f| current[f].is_a?(Numeric) }
          return :unrecomputable unless field

          current.merge(field => current[field] * amount)
        elsif current.is_a?(Numeric)
          current * amount
        else
          :unrecomputable
        end
      end

      # `CommandRules::Arithmetic#clamp`'s own two branches, reproduced
      # the same way #recompute_multiply is — including THIS SESSION'S
      # OWN `current ||= 0` fix (command_rules/arithmetic.rb), the one
      # arithmetic op that didn't have it until now. `mutation.source`
      # is always a literal `[min, max]`, never an argument reference
      # (MutationApplier's own comment on why `resolve_source` is
      # skipped for clamp) — so nothing here reads `args` for it at all.
      def recompute_clamp(current, bounds)
        return :unrecomputable unless bounds.is_a?(Array) && bounds.size == 2

        min, max = bounds
        current ||= 0
        if current.is_a?(Hash)
          field = current.keys.find { |f| current[f].is_a?(Numeric) }
          return :unrecomputable unless field

          current.merge(field => current[field].clamp(min, max))
        elsif current.is_a?(Numeric)
          current.clamp(min, max)
        else
          :unrecomputable
        end
      end

      # `CommandRules::Arithmetic#resolve_source`, reproduced: a
      # mutation's source is either the NAME OF AN ARGUMENT or a
      # LITERAL, told apart by type.
      def resolve_mutation_source(source, args)
        source.is_a?(Symbol) ? args[source] : source
      end

      # A generated step's own `args` arrive with STRING keys on every
      # nested Hash (the wire/JSON shape `spec/corpus/*.json` already
      # uses) while `history[:mutation_traces]`' own materialized
      # before/after state carries SYMBOL keys throughout (Runtime::
      # Value.materialize's own convention) — two hashes holding the
      # identical fact compare UNEQUAL by Ruby's own `Hash#==` unless
      # both sides are normalized the same way first. Recursive, since
      # an appended/removed element can itself nest a value object
      # (RemoveTag's own `Tag` argument, `{"key"=>..., "value"=>...}`).
      def symbolize_deep(value)
        case value
        when Hash  then value.to_h { |key, val| [key.to_sym, symbolize_deep(val)] }
        when Array then value.map { |val| symbolize_deep(val) }
        else value
        end
      end

      # EVERY STORED RECORD STILL SATISFIES ITS OWN AGGREGATE'S DECLARED
      # INVARIANTS — Admissibility#enforce_invariants (command_rules/
      # admissibility.rb) checks these AFTER every command's mutations,
      # BEFORE save, the same point `ensures` is checked. Nothing until
      # now re-checked a record AFTER a whole replay finished, independent
      # of whichever call site was supposed to have refused a violation
      # in the first place — a record failing its own declared invariant
      # here is proof a violating write landed anyway: the call site
      # stopped calling enforce_invariants, or some other path (a
      # translation, a backfill) wrote around it entirely.
      #
      # `history[:instances]` entries are already plain, symbol-keyed
      # state Hashes (Replay.call's own `record.state`) — called against
      # Evaluator.call the SAME way ValueObject::Builder#build already
      # does for a VO's own invariants (value/coercion.rb), no GuardState
      # wrapper needed the way enforce_invariants' own LIVE call uses one
      # (GuardState exists for `parent.`/projected-field dereferencing
      # mid-dispatch; a stored record's own scalar fields need none of
      # that to re-check a same-aggregate invariant against itself).
      #
      # Real target: Account's own `invariant("the balance never goes
      # negative") { balance.cents >= 0 }`.
      #
      # Entity#invariants (round 7) closes here too, not for free —
      # `stored_records_satisfy_declared_invariants` only ever checked
      # the AGGREGATE's own flat state; a piece's own invariant is
      # checked against every ELEMENT of a `list_of` field, a genuinely
      # different walk `check_piece_invariants` below makes,
      # independently of `Admissibility#check_entity_invariants` (the
      # live enforcement path this property exists to catch drifting
      # from) — same reasoning `stored_records_satisfy_declared_
      # invariants`' own top-level check already applies one level up.
      #
      # Real target: SafeDepositBox's own Visit — `invariant("a written
      # note is not blank") { !note || !note.text.to_s.empty? }`.
      def stored_records_satisfy_declared_invariants(history)
        bluebooks = history.fetch(:bluebooks)

        offenders = history.fetch(:instances).filter_map do |key, state|
          domain_name    = key.split("::").first
          aggregate_name = key.split("::").last.split("#").first
          bluebook       = bluebooks[domain_name]
          aggregate      = bluebook&.aggregate(aggregate_name)
          next unless aggregate

          violated = aggregate.invariants.find do |invariant|
            !Bluebook::Expression::Evaluator.call(invariant.canonical, state)
          end
          next "#{key} violates #{aggregate_name}'s own declared invariant #{violated.description.inspect}" if violated

          check_piece_invariants(aggregate, state, key)
        end

        offenders.empty? || offenders.join("; ")
      end

      # A PIECE'S OWN INVARIANT, checked against every element a
      # `list_of` field holds — the SAME lookup `Admissibility#
      # check_entity_invariants` makes (`owner.attributes.find { |a|
      # a.list? && a.type.to_s == entity.hecks_name }`), independently
      # reapplied here against a STORED record's own plain Hash state
      # rather than a live `Instance`.
      def check_piece_invariants(owner_construct, owner_state, key)
        owner_construct.entities.each do |entity|
          next if entity.invariants.empty?

          list_attr = owner_construct.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name }
          next unless list_attr

          Array(owner_state[list_attr.name]).each do |element|
            violated = entity.invariants.find do |invariant|
              !Bluebook::Expression::Evaluator.call(invariant.canonical, element)
            end
            return "#{key}'s own #{entity.hecks_name} violates its declared invariant #{violated.description.inspect}" if violated

            nested = check_piece_invariants(entity, element, key)
            return nested if nested
          end
        end
        nil
      end

      # A SAGA INSTANCE'S OWN CHECKPOINT SURVIVES BEING WRITTEN AND READ
      # BACK — the durability contract `SagaInterpreter#checkpoint` makes
      # (`state:` plus a `deep_copy`d `memory:`, handed to whatever
      # adapter answers `save_saga`) and `Registry#rehydrate_sagas!`
      # promises to restore on the next boot (`each_saga` yielding
      # `[pm, correlation, state, memory]` back into `saga_instances`).
      # `Replay` captures the LIVE store already materialised the same
      # way `checkpoint` itself does (`Value.materialize`, not raw
      # `Runtime::Value`s — see its own comment); this property pushes
      # that captured memory through the SAME `JSON.generate` then
      # `JSON.parse(symbolize_names: true)` round-trip `checkpoint`'s own
      # `deep_copy` performs (mirrored here rather than called — a
      # private instance method with no registry to hand it) and checks
      # it comes back byte-identical. A memory holding anything that
      # round-trip cannot carry faithfully — a bare Symbol leaf, a
      # non-JSON type a future field introduces — is corruption the
      # durable path would introduce on a REAL restart, caught here
      # without needing one.
      #
      # `declares_state?` (Behaviour::ProcessManager) is the other half:
      # a live or rehydrated instance sitting in a state the procedure
      # never declares is the saga-durability twin of
      # `lifecycle_values_are_declared` above.
      def sagas_rehydrate_cleanly(history)
        bluebook = history.fetch(:bluebook)
        process_managers = bluebook.process_managers.to_h { |pm| [pm.name, pm] }

        offenders = history.fetch(:saga_instances).flat_map do |pm_name, conversations|
          pm = process_managers[pm_name]

          conversations.filter_map do |correlation, instance|
            problems = []

            problems << "holds state #{instance[:state].inspect}, which #{pm_name} never declares" if pm && !pm.declares_state?(instance[:state])

            rehydrated = JSON.parse(JSON.generate(instance[:memory]), symbolize_names: true)
            if rehydrated != instance[:memory]
              problems << "memory does not survive its own checkpoint round-trip " \
                          "(checkpointed #{instance[:memory].inspect}, rehydrated #{rehydrated.inspect})"
            end

            next if problems.empty?

            "#{pm_name}##{correlation.inspect}: #{problems.join(' and ')}"
          end
        end

        offenders.empty? || offenders.join("; ")
      end

      # A `for_each` POLICY DISPATCHES EXACTLY ONCE PER ROW ITS DECLARED
      # QUERY ANSWERS — never once for the triggering event regardless of
      # row count, never skipping a matched row, never firing on a row a
      # concurrent mutation only made match AFTER the fact. `Replay`
      # computes the expected row-id set INDEPENDENTLY, at the same
      # instant the real dispatch runs (`Replay.expected_fan_out_rows`,
      # the query oracle's own shape aimed at fan-out: two engines
      # compared, never one graded against itself), and records it
      # beside what the reaction log actually shows. `expected_row_ids`
      # is `nil`, not `[]`, when `policy.where` did not hold — no
      # dispatch is the claim then, not "dispatched to zero rows," and a
      # policy that dispatched anyway despite a failing guard is as real
      # a finding as a row it skipped.
      def fanout_dispatches_once_per_matching_row(history)
        offenders = history.fetch(:fan_outs).filter_map do |finding|
          expected = finding[:expected_row_ids]
          actual   = finding[:actual_row_ids].sort

          if expected.nil?
            next if actual.empty?

            next "#{finding[:policy]} on #{finding[:on]}: where did not hold, but dispatched to #{actual.inspect}"
          end

          next if actual == expected

          "#{finding[:policy]} on #{finding[:on]}: for_each answered #{expected.inspect}, " \
            "but the reaction log shows dispatches to #{actual.inspect}"
        end

        offenders.empty? || offenders.join("; ")
      end

      # A `count`/`median` REPORT'S REDUCED SCALAR MATCHES THE SAME
      # REDUCTION DONE INDEPENDENTLY, over the SAME eligible rows —
      # `ReadModelInterpreter#project`'s own FK-join (root first, then
      # each many-side head matched against it) and `#median` (odd →
      # the true middle, even → the average of the two middles as a
      # Float, empty → `nil`; `count` is the filtered length, empty →
      # `0`), reproduced here in plain Ruby against `history[:instances]`
      # rather than a live registry — `FieldPath.dig` +
      # `Ports::Query::InMemory.comparable`/`.holds?` are the SAME two
      # calls the interpreter itself makes to read a field and judge a
      # `where`, called here rather than re-derived, so this oracle
      # cannot drift from what "read a field" or "a clause holds" mean
      # without the interpreter drifting the identical way.
      #
      # Only a report whose `:query` is answered by the SAME bluebook
      # `history[:bluebook]` carries (the bare `Domain.report_name`
      # form, `domain == bluebook.name`) is checked — the same "only
      # what we have the grammar for" scope `lifecycle_values_are_declared`
      # already takes for a multi-domain replay.
      def aggregation_matches_recompute(history)
        bluebook = history.fetch(:bluebook)

        offenders = history.fetch(:queries).filter_map do |asked|
          next if asked[:error]

          domain, name = asked[:query].to_s.split(".", 2)
          next unless name && domain == bluebook.name

          model = bluebook.read_model(name)
          next unless model && (model.count? || model.median_field)

          reduced_head = model.aggregate_heads.find { |head| head[:many] }
          next unless reduced_head

          rows = eligible_rows(bluebook, asked.fetch(:instances_at), domain, model, reduced_head, asked[:args] || {})
          expected = model.count? ? rows.length : recompute_median(rows, model.median_field)
          actual = asked[:rows]&.first&.dig(reduced_head[:as])
          next if actual == expected

          "#{asked[:query]} #{asked[:args].inspect} answered #{actual.inspect} for #{reduced_head[:as]}, " \
            "but recomputing independently from #{rows.length} eligible row(s) gives #{expected.inspect}"
        end

        offenders.empty? || offenders.join("; ")
      end

      # `aggregation_matches_recompute`'s own shape, extended from
      # reducing a many-side head to a scalar (count/median) to NESTING
      # it — `ReadModelInterpreter#group_by_target`/`#nest`, reproduced
      # here in plain Ruby against `history[:instances]` the same way
      # `eligible_rows` already reproduces the FK-join and `where`
      # narrowing count/median share. `Value.materialize_unwrapped` is
      # the SAME call `#project` makes before nesting (a single-field
      # value object recurses to its bare scalar — a real grouping key
      # has to BE one) — called here rather than re-derived, so this
      # oracle cannot drift from what "the group key" means without the
      # interpreter drifting the identical way.
      #
      # Real target: AccountsByKind (`group_by :kind, :number`,
      # rootless — always generator-eligible with `{}` args).
      def group_by_matches_recompute(history)
        bluebook = history.fetch(:bluebook)

        offenders = history.fetch(:queries).filter_map do |asked|
          next if asked[:error]

          domain, name = asked[:query].to_s.split(".", 2)
          next unless name && domain == bluebook.name

          model = bluebook.read_model(name)
          next unless model && model.group_by.any?

          grouped_head = model.aggregate_heads.find { |head| head[:many] }
          next unless grouped_head

          rows = eligible_rows(bluebook, asked.fetch(:instances_at), domain, model, grouped_head, asked[:args] || {})
          materialized = rows.map { |state| Runtime::Value.materialize_unwrapped(state) }
          expected = nest_rows(materialized, model.group_by_fields)
          actual = asked[:rows]&.first&.dig(grouped_head[:as])
          next if actual == expected

          "#{asked[:query]} #{asked[:args].inspect} answered a #{grouped_head[:as]} grouping that disagrees " \
            "with independently nesting group_by #{model.group_by_fields.inspect} over #{rows.length} " \
            "eligible row(s)"
        end

        offenders.empty? || offenders.join("; ")
      end

      # `ReadModelInterpreter#nest`, byte for byte: one level of nesting
      # per `group_by` field in declared order, leaf is the row with
      # every grouped field stripped (already spent, as the keys that
      # reached it).
      def nest_rows(rows, fields)
        field, *rest = fields
        rows.group_by { |row| row[field] }.transform_values do |group|
          stripped = group.map { |row| row.reject { |key, _| key == field } }
          rest.empty? ? stripped.first : nest_rows(stripped, rest)
        end
      end

      # THE ELIGIBLE ROWS a `count`/`median` head reduces — every
      # instance of the reduced head's own aggregate, FK-matched against
      # the report's root reference (if it has one; a rootless report has
      # none to match) exactly the way `ReadModelInterpreter#reference_fields`
      # finds the matching attribute, then narrowed by the report's own
      # `where` clauses via the SAME `InMemory.holds?` the interpreter's
      # `execute` calls.
      def eligible_rows(bluebook, instances, domain, model, reduced_head, args)
        aggregate = bluebook.aggregate(reduced_head[:aggregate])
        prefix = "#{domain}::#{reduced_head[:aggregate]}#"
        # `id:` MERGED IN, the same `record.to_h` (`@state.merge(id:
        # @id)`) every live head row carries — count/median never read
        # it, but group_by_matches_recompute's own independent nesting
        # does, the same way ReadModelInterpreter#row(record) = record.
        # to_h does for the live path it's checking against.
        rows = instances.filter_map { |key, state| state.merge(id: key.split("#").last) if key.start_with?(prefix) }

        if model.reference_target
          reference_id = args[model.reference_name].to_s
          fk_fields = aggregate.attributes.select do |attribute|
            attribute.reference? && attribute.type.target_name == model.reference_target.to_s
          end.map(&:name)

          rows = rows.select { |state| fk_fields.any? { |field| state[field].to_s == reference_id } }
        end

        rows.select do |state|
          model.wheres.all? do |clause|
            held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(state, clause.field))
            Ports::Query::InMemory.holds?(clause, held, args)
          end
        end
      end

      # `ReadModelInterpreter#median`'s own definition, reproduced byte
      # for byte: odd count → the true middle value, sorted; even count
      # → the average of the two middle values, as a Float; empty → nil,
      # never zero, so a caller cannot mistake "nothing to average" for
      # "averaged to zero."
      def recompute_median(rows, field)
        values = rows.map { |state| Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(state, field)) }
                     .compact.sort
        return nil if values.empty?

        middle = values.length / 2
        values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
      end

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
