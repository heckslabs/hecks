require "fileutils"
require "tmpdir"
require_relative "isolated_boot"
require_relative "../query_specification/common/comparators"
require_relative "../query_specification/common/where_clause"
require_relative "../query_specification/field_path"
require_relative "../ports/query/in_memory"

module Hecks
  module Fuzzing
    # A step list, replayed IN-PROCESS against a fresh boot — the same
    # copy-to-tmp-and-reset preamble SequenceGenerator#call uses, and the
    # same observable surface bin/run prints (instances, events,
    # refusals, reactions, sagas, queries), but returned as data rather
    # than JSON on stdout.
    #
    # NOT what SequenceGenerator itself dispatches through while
    # generating — that inline execution feeds the picker's own
    # known_ids tracking and stays exactly as it is. This exists for
    # everything ELSE that needs "given a step list, boot fresh and tell
    # me what happened": bin/fuzz recomputing a shrink candidate's TRUE
    # event count (removing a step changes what the sequence actually
    # produces, so a shrunk candidate cannot reuse the original claim),
    # and the declared-property checks in properties.rb. Both want it
    # in-process — a property or a shrink-candidate check is a question
    # this boot can answer itself, and paying for a subprocess and a
    # second boot to ask it would be ~100x the cost for nothing.
    #
    # Refuses the same way SequenceGenerator's own safe_call does: a
    # DOMAIN_REFUSAL or an EvaluationError is the domain declining a
    # step, recorded and not fatal to the replay. Anything else
    # propagates — a step that breaks the interpreter is a defect, not
    # an observation to fold quietly into the history.
    module Replay
      module_function

      # THE AD HOC FILTER'S OWN COMPARATOR ROSTER — read directly from
      # QuerySpecification::Common::COMPARATORS (the same nine names
      # Vocabulary::QueryComparator declares), never re-typed. A
      # declared bluebook query never sees an `op:` outside this set —
      # `admits: "Vocabulary::QueryComparator"` refuses one at DECLARE
      # time — but a `"filter"`-shaped query step (below) has no
      # declare-time gate at all, so this method gates it here instead.
      #
      # NOT rust/src/kernel/query_comparators.rs's own ground truth —
      # that hand-maintained Rust enum is missing `none_in_state` (the
      # 9th comparator, added after the enum was written) and has
      # already drifted; do not treat it as authoritative until item #9
      # of the whole-project table-unification survey closes that gap.
      FILTER_COMPARATORS = Hecks::QuerySpecification::Common::COMPARATORS.map(&:to_s).freeze

      # THE TWO CLASSES `#enforce_givens`/`#enforce_lifecycle_guard`
      # themselves ever raise — see Admissibility's own doc comment,
      # `command_rules/admissibility.rb`. Any OTHER DOMAIN_REFUSAL a step
      # raises (TypeMismatch, EnsuresNotMet, InvariantViolation, ...)
      # proves the guard itself did NOT fire, since it runs first in
      # DISPATCH_ORDER.
      GUARD_REFUSAL_CLASSES = [Runtime::GivenNotMet, Runtime::LifecycleRefused].freeze

      def call(domain_path, steps)
        # See isolated_boot.rb's own header: resets data/ AND rebinds
        # persistence to Memory, since a Postgres-bound domain's real store
        # lives outside the copied directory and cannot be reached by
        # resetting data/ alone.
        IsolatedBoot.call(domain_path) do |copy|
          runtime = Hecks.boot(copy)

          refusals        = []
          queries         = []
          dry_runs        = []
          fan_outs        = []
          guard_checks    = []
          mutation_traces = []

          # EVERY AGGREGATE A `for_each` COULD EVER QUERY, resolved ONCE —
          # `[domain, aggregate_name]` pairs, gleaned from every loaded
          # bluebook's own fanning-out policies. Empty for every domain
          # with no `for_each` at all (every example this corpus ships
          # today), so the snapshot below costs nothing until a domain
          # actually declares one.
          fan_out_targets = runtime.registry.bluebooks.each_with_object({}) do |(domain, bluebook), targets|
            bluebook.policies.select(&:fans_out?).each do |policy|
              query_domain, aggregate_name, = policy.for_each_route(domain)
              targets[[query_domain, aggregate_name]] ||= runtime.registry.bluebook(query_domain)&.aggregate(aggregate_name)
            end
          end

          steps.each do |step|
            step = step.transform_keys(&:to_s)
            args = (step["args"] || {}).transform_keys(&:to_sym)

            if (question = step["query"])
              # THE AD HOC, SINGLE-COMPARATOR FILTER — a "query" step whose
              # own value is a Hash, not a name: `{aggregate:, field:, op:,
              # value:}`, the SAME wire shape kernel/cli.rs's new object-
              # form "query" step reads on the Rust side (that file's own
              # header explains why this shape exists at all: it bypasses
              # the bluebook query DSL entirely, so it needs no generated
              # per-domain codegen to prove for real). Answered here by
              # calling `Ports::Query::InMemory` DIRECTLY — the real
              # production comparator engine, not a second, hand-rewritten
              # copy of it — against the raw repository, never through
              # `runtime.query`, which only ever resolves a NAMED, declared
              # ask.
              if question.is_a?(Hash)
                begin
                  rows = run_filter(runtime, question)
                  queries << { query: question, rows: rows, instances_at: snapshot_instances(runtime) }
                rescue => e
                  refusals << { verb: filter_label(question), error: e.message }
                end
                next
              end

              begin
                rows = runtime.query(question, **args)
                # THE QUERY ORACLE'S OTHER HALF — the same ask at the same
                # instant, answered by the reference interpreter instead of
                # the bound adapter's native hook. Recorded side by side so
                # Properties.query_answers_match_reference can treat any
                # difference as a finding. Read-model asks (bare domain
                # form, no "::") have no reference twin and record only the
                # one answer.
                reference = question.include?("::") ? runtime.reference_query(question, **args) : nil
                queries << { query: question, args: args, rows: rows, reference_rows: reference,
                             instances_at: snapshot_instances(runtime) }
              rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
                queries << { query: question, args: args, error: e.message }
                refusals << { verb: question, error: e.message, kind: e.class.name }
              end
              next
            end

            # `{"dry_run": verb, "args": …}` — `Dispatcher#dry_run?`: the command
            # evaluated hypothetically, nothing saved or emitted, no reaction.
            # Recorded, never a refusal: a refused dry run is an ANSWER.
            if (hypothetical = step["dry_run"])
              begin
                runtime.dry_run?(hypothetical, **args)
                dry_runs << { verb: hypothetical, ok: true }
              rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
                dry_runs << { verb: hypothetical, ok: false, error: e.message }
              end
              next
            end

            begin
              # THE FAN-OUT ORACLE'S OWN LOW-WATER MARK — taken before
              # dispatch, so any reaction this ONE step's own announced
              # events produce (`reaction_log` grows in place, the same
              # Array `runtime.reactions` already exposes) can be sliced
              # out after, and matched against an INDEPENDENT recomputation
              # of what a `for_each` policy should have fanned out over —
              # the query oracle's own shape (two engines, compared, never
              # one graded against itself), aimed at fan-out instead of a
              # named ask.
              reaction_mark = runtime.reactions.size

              # THE SNAPSHOT A `for_each` QUERY WOULD HAVE SEEN — taken
              # BEFORE this step's own dispatch, not after. The real
              # `deliver_for_each` runs its query SYNCHRONOUSLY, inside
              # this SAME dispatch, before this call even returns — so an
              # oracle that re-reads the live repository AFTER `dispatch`
              # answers sees whatever the fan-out's OWN dispatched
              # commands already mutated (an Account a `Review` leg just
              # moved out of "open," say), not what the query actually
              # matched. A measured bug, not a hypothetical one — this
              # exact ordering is what `spec/fuzzing/fan_out_spec.rb`'s
              # own adversarial run against a live `for_each` policy
              # caught the first time this shipped without it.
              fan_out_snapshot = fan_out_targets.each_with_object({}) do |((fdomain, faggregate_name), aggregate), snap|
                next unless aggregate

                snap[[fdomain, faggregate_name]] =
                  runtime.registry.repository(fdomain, aggregate).all.to_h { |record| [record.id, record.state.dup] }
              end

              # THE GUARD ORACLE'S OWN PRE-DISPATCH READ — same idiom,
              # same placement, same reason as fan_out_snapshot right
              # above: `Admissibility#enforce_givens` (which itself calls
              # `#enforce_lifecycle_guard` when `declaring:` is passed)
              # is called a SECOND time here, independently, against the
              # record exactly as CommandInterpreter#hydrate's own acting
              # branch would find it (`repository.find(id).dup` — the
              # identical three-tier id fallback, Identity.of/.from,
              # reproduced read-only) — BEFORE this step's real dispatch
              # can mutate anything a cross-aggregate given dereferences
              # (`customer.status`). A pure predicate read, side-effect
              # free, so calling it twice changes nothing this step
              # itself observes.
              guard_check = build_guard_check(runtime, step["verb"], args)

              # THE MUTATION ORACLE'S OWN PRE-DISPATCH READ — same
              # idiom again: an ENTITY-DISPATCHED command's own
              # `append`/`remove`/`multiply`/`clamp` mutations (S17's
              # fixture, spec/fixtures/entity_list_mutations, now a real
              # bootable domain) act on the entity's OWN attributes, so
              # the element addressed by this step's own identity args
              # is snapshotted BEFORE dispatch, materialized to plain
              # data — `nil` for anything out of scope (an aggregate-
              # level command, an entity command with no mutations at
              # all, or one whose identity args don't resolve).
              mutation_trace = build_mutation_trace(runtime, step["verb"], args)

              # `role:` — an OPTIONAL per-step key, absent on every one of
              # the 231 existing `spec/corpus/*.json` steps (their own
              # unwrapped `runtime.dispatch` call, unchanged, so nothing
              # already pinned changes behavior). Binds the SAME ambient
              # caller `refuse_role_mismatch` reads (`Hecks.as_caller`,
              # `Runtime::Caller.as`) for exactly the one dispatch this
              # step makes, then unbinds — mirrors `Caller.as`'s own
              # `ensure`-restore, so back-to-back steps with different (or
              # no) `role:` never leak into each other.
              result = if step["role"]
                         Hecks.as_caller(role: step["role"]) { runtime.dispatch(step["verb"], **args) }
                       else
                         runtime.dispatch(step["verb"], **args)
                       end

              fan_outs.concat(fan_out_findings(runtime, fan_out_snapshot, result.events, runtime.reactions[reaction_mark..]))
              guard_checks << guard_check.merge(actual_refused: false, actual_kind: nil) if guard_check
              # AFTER — only on SUCCESS ; a refused step mutated nothing,
              # so there is no "after" to compare (and #build_mutation_
              # trace already skipped anything with no mutations to
              # trace in the first place).
              if mutation_trace
                mutation_traces << mutation_trace.merge(after: read_mutation_after(runtime, mutation_trace))
              end
            rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
              # `kind:` — the RAISED CLASS, not re-derived from the message.
              # `GivenNotMet`/`EnsuresNotMet` share their exact wording
              # ("<command> refused — <description>") with FOUR other
              # refusal templates (Vocabulary's own LifecycleRefused/
              # TypeMismatch/Unauthorized entries) — a property that told
              # a guard refusal apart by pattern-matching the string alone
              # would misread every one of those as a guard, or a guard as
              # one of those. The class is unambiguous where the string
              # is not.
              refusals << { verb: step["verb"], error: e.message, kind: e.class.name }
              # ONLY a refusal raised BY THE GUARD ITSELF counts here —
              # measured, not assumed: a step whose args were simply
              # incomplete (AbsentArgument, from normalize_args — which
              # runs BEFORE enforce_givens in DISPATCH_ORDER) never
              # reached the guard at all, and this oracle's own first
              # live run against real generated pizzas data caught
              # exactly that case as a false positive (a malformed-args
              # step the generator deliberately produces, `amount:`
              # dropped entirely) before this comment existed. Whether a
              # refusal from a stage AFTER enforce_givens (TypeMismatch
              # on a mutation, EnsuresNotMet, InvariantViolation) proves
              # the guard passed can't be told apart from a same-shaped
              # refusal from a stage BEFORE it by class alone (TypeMismatch
              # can come from either), so anything that isn't one of the
              # two guard classes is left OUT of guard_checks entirely —
              # inconclusive, not a claimed pass.
              if guard_check && GUARD_REFUSAL_CLASSES.include?(e.class)
                guard_checks << guard_check.merge(actual_refused: true, actual_kind: e.class.name)
              end
            end
          end

          instances = snapshot_instances(runtime)

          events = runtime.events.map { |event|
            { name: event.name, aggregate: event.aggregate, id: event.id, payload: event.payload }
          }

          # THE LIVE PROCESS-MANAGER STORE, materialised to inert data —
          # `{ pm_name => { correlation => { state:, memory: } } }`, the
          # SAME shape SagaInterpreter#checkpoint hands its persistence
          # adapter (state plus a `Value.materialize`d memory, which is
          # exactly what `deep_copy` there serialises). Captured here
          # because Replay returns the history, not the runtime, and the
          # runtime goes out of scope with the boot — so the saga-durability
          # property (Properties.sagas_rehydrate_cleanly) reads this rather
          # than reaching into a store the Memory rebind leaves as the
          # no-op NULL_SAGA_STORE. Materialised, not raw, so the history
          # stays plain data AND the round-trip check sees exactly the
          # bytes a real adapter would have persisted.
          saga_instances = runtime.registry.saga_instances.each_with_object({}) do |(pm_name, conversations), out|
            out[pm_name] = conversations.each_with_object({}) do |(correlation, instance), rows|
              rows[correlation] = { state: instance[:state], memory: Runtime::Value.materialize(instance[:memory]) }
            end
          end

          # The booted chapter rides along — the boot already happened, and
          # properties.rb's lifecycle/saga checks need the declared IR
          # (state sets, handler graphs) beside the history it produced.
          # Free: no second boot, just the object the first one already
          # built.
          #
          # `bluebook:` (singular) stays the FIRST-loaded chapter — every
          # existing property scopes itself to "only what we have the
          # grammar for" against exactly this one, deliberately (see
          # lifecycle_values_are_declared's own comment). `bluebooks:`
          # (plural) is the FULL map, keyed by domain name — a domain
          # under fuzz commonly composes more than one bluebook (banking
          # alone loads Banking + Governance + Identity), and a refusal
          # or an event can legitimately come from ANY of them, not only
          # whichever one happened to load first. A property that needs
          # to resolve a verb back to its OWN declaring bluebook — not
          # "the" bluebook — reads this instead.
          { instances: instances, events: events, refusals: refusals,
            reactions: runtime.reactions, sagas: runtime.sagas, saga_instances: saga_instances,
            queries: queries, dry_runs: dry_runs, fan_outs: fan_outs, guard_checks: guard_checks,
            mutation_traces: mutation_traces,
            saga_dispatches: runtime.saga_dispatches, policy_dispatches: runtime.policy_dispatches,
            bluebook: runtime.registry.bluebooks.values.first,
            bluebooks: runtime.registry.bluebooks.dup }
        end
      end

      # THE GUARD ORACLE'S OWN RESOLUTION — "which record, if any, is
      # this step about, and would enforce_givens/enforce_lifecycle_guard
      # have refused it against that record's PRE-DISPATCH state" —
      # reproduced read-only from already-public pieces
      # (Naming.split_verb, registry.bluebook/.aggregate/.command,
      # Runtime::Identity.of/.from, repository.find), the exact same
      # three-tier fallback CommandInterpreter#hydrate's OWN acting
      # branch uses, minus its creating/duplicate-checking logic (a
      # creating command has no pre-existing record to snapshot, and
      # every real target this closes — Debit/CloseAccount/Credit/
      # FreezeAccount — already acts on one).
      #
      # `nil` for anything out of scope: an entity/port verb (a dotted
      # command_name — EntityInterpreter's own enforce_givens call,
      # `parent:`-shaped, is a different call signature this does not
      # reproduce), a creating command, an unresolvable id, or a command
      # that declares neither `givens` nor `from` at all (nothing to
      # check — logging a guaranteed, tautological pass would be noise,
      # not a finding, the same reason `aggregation_matches_recompute`
      # skips a read model with no count/median declared).
      #
      # Never lets a resolution surprise (a malformed verb, a dangling
      # reference) become the step's own real dispatch outcome — this
      # is a SEPARATE, best-effort read, not part of the step's own
      # control flow.
      # THE SAME SHAPE `call`'s own end-of-replay block used to build
      # inline — every persisted record, keyed the way `query_eligible_rows`/
      # `#eligible_rows` (properties.rb) already expect. Now ALSO called
      # once PER QUERY STEP (see `call`, above), not only once at the very
      # end: a query asked at step 1 of a script whose LATER steps go on
      # to create more records was being checked, by every property that
      # independently recomputes "the eligible rows," against the FINAL
      # snapshot — the records that existed AFTER the whole replay, not
      # the ones that existed when the query actually ran. Found live:
      # `Banking.accounts_by_kind`, asked as literally the first step of a
      # 3-step script, correctly answered against zero accounts (none
      # existed yet) while `group_by_matches_recompute`'s own independent
      # recompute claimed "1 eligible row" — the ONE account the script's
      # later two steps went on to create. Each query step now carries
      # its own `instances_at:` snapshot, taken at the moment it ran, so
      # every property that recomputes against "the eligible rows" reads
      # the state as that query actually saw it, not a shared final one.
      def snapshot_instances(runtime)
        instances = {}
        runtime.registry.bluebooks.each do |domain_name, bluebook|
          bluebook.aggregates.each do |aggregate|
            runtime.registry.repository(domain_name, aggregate).all.each do |record|
              instances["#{domain_name}::#{aggregate.name}##{record.id}"] = record.state
            end
          end
        end
        instances
      end

      def build_guard_check(runtime, verb, args)
        domain_name, aggregate_name, command_name = Naming.split_verb(verb)
        return nil unless command_name && !command_name.include?(".")

        aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
        command   = aggregate&.command(command_name)
        return nil unless aggregate && command && !command.creates?

        # NOTHING TO CHECK, genuinely — not "nothing THIS reproduces yet".
        # A transition-only guard (no per-command `from:`, no `given`,
        # only an aggregate `lifecycle do transition ... end` block
        # naming this command — `Admit`/`Reject`'s own shape) still
        # counts as something to check now that `admissible_transition`
        # is reproduced below; skipping it here would just move the
        # exact gap that call was added to close one line earlier.
        has_transition = aggregate.lifecycle && aggregate.lifecycle.transitions_for(command.hecks_name).any?
        return nil if command.givens.empty? && !command.from && !has_transition

        reference_key = command.references.to_s.empty? ? nil : Naming.reference_key(command.references)
        id = Runtime::Identity.of(aggregate, args) ||
             Runtime::Identity.from(aggregate, args, :id) ||
             (reference_key && Runtime::Identity.from(aggregate, args, reference_key))
        return nil unless id

        record = runtime.registry.repository(domain_name, aggregate).find(id)
        return nil unless record

        rules = Runtime::CommandRules.new(runtime.registry)
        recomputed_kind = begin
          rules.enforce_givens(record.dup, command, args, domain: domain_name, declaring: aggregate)

          # A SECOND, SEPARATE DISPATCH_ORDER STEP — `enforce_givens`
          # (just above) only ever checks a per-COMMAND `from:` clause
          # (its own trailing `enforce_lifecycle_guard(declaring, ...)
          # if declaring` call) — the aggregate's own `lifecycle do
          # transition "X" => Y, from: Z end` block is a WHOLLY separate
          # method (`admissible_transition`), called as its own later
          # DISPATCH_ORDER step (`:enforce_givens` then
          # `:admissible_transition` — Vocabulary.symbols
          # ("AggregateDispatchOrder")), not reached from inside
          # `enforce_givens` at all. Missing this call meant a command
          # declared with NO per-command `from:` of its own — every real
          # transition-guarded command in this corpus, `Admit`/`Reject`
          # included — always recomputed "admitted" no matter the
          # record's actual state, because the ONE check that would
          # have refused it was never run. Found live: `Expression::
          # Expression.Admit`, fuzzed against `lib/hecks/grammar`
          # (a domain the property's own hand-verification — Banking,
          # Pizzas — never happened to exercise a transition-guarded,
          # no-per-command-`from:` command against). Called only when
          # `enforce_givens` didn't already refuse, mirroring the real
          # pipeline's own "first refusal wins" order exactly.
          rules.admissible_transition(aggregate, command, record.dup)
          nil
        rescue *GUARD_REFUSAL_CLASSES => e
          e.class.name
        end

        { verb: verb, domain: domain_name, aggregate: aggregate_name, command: command_name, id: id,
          recomputed_refused: !recomputed_kind.nil?, recomputed_kind: recomputed_kind }
      rescue StandardError
        nil
      end

      # THE MUTATION ORACLE'S OWN PRE-DISPATCH READ — scoped, on
      # purpose, to ENTITY-DISPATCHED commands only (a dotted
      # command_name): the one place `append`/`remove`/`multiply`/
      # `clamp` are known to act on an entity's OWN attributes
      # (spec/fixtures/entity_list_mutations' own TaggedList — `tags`
      # a value-object list, `count` a VO-typed scalar), never on
      # ANOTHER nested entity list — so this never needs to reproduce
      # `MutationApplier#entity_element`'s own auto-mint/collision logic
      # (item 1's own fix) at all. An aggregate-level command whose OWN
      # mutation appends an ENTITY (`Board.AddList`, `SafeDepositBox.
      # LogVisit`) is a DIFFERENT, already-covered case — item 1's own
      # collision property, not this one.
      #
      # `nil` for anything out of scope: an aggregate-level command, an
      # entity command with no mutations at all, or one whose identity
      # args (parent OR element) don't resolve.
      def build_mutation_trace(runtime, verb, args)
        domain_name, aggregate_name, command_name = Naming.split_verb(verb)
        return nil unless command_name && command_name.include?(".")

        aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
        return nil unless aggregate

        entity_name, entity_command_name = command_name.split(".", 2)
        entity  = aggregate.entities.find { |candidate| candidate.hecks_name == entity_name }
        command = entity&.command(entity_command_name)
        return nil unless command && command.mutations.any?

        reference_key = command.references.to_s.empty? ? nil : Naming.reference_key(command.references)
        parent_id = Runtime::Identity.of(aggregate, args) ||
                    Runtime::Identity.from(aggregate, args, :id) ||
                    (reference_key && Runtime::Identity.from(aggregate, args, reference_key))
        return nil unless parent_id

        record = runtime.registry.repository(domain_name, aggregate).find(parent_id)
        return nil unless record

        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name }
        return nil unless list_attr

        wants = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          raw  = args[head]
          return nil if raw.nil?

          [head, Runtime::Value.for_attribute(aggregate, entity.attribute(head), raw)]
        end

        element = Array(record.state[list_attr.name]).find { |el| wants.all? { |head, want| el[head] == want } }
        return nil unless element

        { verb: verb, domain: domain_name, aggregate: aggregate_name, command: command_name,
          parent_id: parent_id, list_attr: list_attr.name, element_wants: wants,
          before: Runtime::Value.materialize(element), args: args }
      rescue StandardError
        nil
      end

      # THE SAME ELEMENT, RE-LOCATED, AFTER dispatch — by identity, not
      # position (an append could have changed the array's own length
      # or order relative to it). `nil` if it somehow vanished (not
      # expected for any op this fixture declares — none of them
      # remove the acted-on element itself — but a property comparing
      # against `nil` fails loudly rather than crashing this replay).
      def read_mutation_after(runtime, trace)
        aggregate = runtime.registry.bluebook(trace[:domain])&.aggregate(trace[:aggregate])
        return nil unless aggregate

        record = runtime.registry.repository(trace[:domain], aggregate).find(trace[:parent_id])
        return nil unless record

        element = Array(record.state[trace[:list_attr]]).find do |el|
          trace[:element_wants].all? { |head, want| el[head] == want }
        end
        element && Runtime::Value.materialize(element)
      rescue StandardError
        nil
      end

      # THE FAN-OUT ORACLE — one finding per (event, for_each policy) this
      # step's own announced events could have triggered, independent of
      # `PolicyInterpreter#deliver_for_each`: the SAME `where` evaluator
      # every given/ensures already runs through, but the QUERY answered
      # by `Ports::Query::InMemory.holds?` directly against the live
      # repository (`Replay.run_filter`'s own idiom), never by calling
      # `QueryInterpreter` — sharing that call would make this oracle
      # blind to exactly the code the fan-out feature adds.
      #
      # `expected_row_ids` is `nil` when `where` did not hold — no dispatch
      # is the claim, not "dispatched to zero rows," so a property
      # comparing this against the reaction log needs to tell the two
      # apart. Recomputed once per event, not once per policy-and-event,
      # because a `Chapter` de-duplicates on nothing this loop cannot
      # cheaply repeat.
      def fan_out_findings(runtime, snapshot, announced, reactions_since)
        announced.each_with_object([]) do |event, findings|
          # `event.aggregate` is domain-qualified ("Banking::Account" —
          # see command_rules/emission.rb's own Event.new) — the SAME
          # source `PolicyInterpreter#policies_for` reads, split the
          # same two ways: `Naming.demodulise` for the emitting
          # aggregate's bare name, plain `split("::")` for the domain.
          domain = event.aggregate.to_s.split("::").first
          bluebook = runtime.registry.bluebook(domain)
          next unless bluebook

          emitting = Naming.demodulise(event.aggregate)

          bluebook.policies.each do |policy|
            next unless policy.fans_out? && policy.event_name == event.name
            next unless policy.event_qualifier.nil? || policy.event_qualifier == emitting

            findings << fan_out_finding(runtime, snapshot, policy, event, domain, reactions_since)
          end
        end
      end

      def fan_out_finding(runtime, snapshot, policy, event, domain, reactions_since)
        payload = event.payload.transform_keys(&:to_sym)
        held = policy.where.to_s.empty? ||
               Bluebook::Expression::Evaluator.call(policy.where, {}, payload)

        expected = held ? expected_fan_out_rows(runtime, snapshot, policy, domain, payload) : nil

        actual = reactions_since.select { |r| r[:policy] == policy.name && r[:on] == event.name }
                                .filter_map { |r| r[:for_row] }

        { policy: policy.name, on: event.name, expected_row_ids: expected, actual_row_ids: actual }
      end

      # THE INDEPENDENT RECOMPUTATION — `policy.for_each`'s declared query,
      # answered against the PRE-DISPATCH snapshot (see the snapshot's
      # own comment at its capture site: the real fan-out's query runs
      # synchronously, before its own dispatched commands can mutate
      # anything the query would have matched, so this has to read the
      # same "before" state or it grades the wrong moment). Comparators
      # are `Ports::Query::InMemory.holds?`, never `QueryInterpreter` —
      # sharing that call would make this oracle blind to exactly the
      # code the fan-out feature adds. A `Symbol` where-value binds to
      # the triggering event's own payload (the same binding
      # `OpenForCustomer`'s `customer_id: :customer_id` relies on); a
      # literal is compared as declared.
      def expected_fan_out_rows(runtime, snapshot, policy, domain, payload)
        query_domain, aggregate_name, query_name = policy.for_each_route(domain)
        aggregate = runtime.registry.bluebook(query_domain)&.aggregate(aggregate_name)
        query = aggregate&.query(query_name)
        return [] unless query

        rows = snapshot[[query_domain, aggregate_name]] || {}
        matched = rows.select do |_id, state|
          query.wheres.all? do |clause|
            held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(state, clause.field))
            Ports::Query::InMemory.holds?(clause, held, payload)
          end
        end

        matched.keys.map(&:to_s).sort
      end

      # Answers ONE ad hoc filter step for real — the mirror image of
      # kernel/cli.rs's own `run_filter`, deliberately calling the exact
      # SAME production module that method's Rust port stands in for
      # (`Ports::Query::InMemory`, lib/hecks/ports/query/in_memory.rb)
      # rather than re-deriving comparator behavior by hand. `field` walks
      # through `QuerySpecification::FieldPath.dig` (the same reading a
      # declared where-clause gets), `comparable`/`holds?` are the same
      # two calls `InMemory.execute` itself makes per candidate record —
      # this is that method's own filter/select step, inlined, because
      # there is no DECLARED `Query` object here to hand `execute` (an ad
      # hoc filter has no `order_by`/`limit`/`offset` at all, so nothing
      # about `execute`'s own ordering/paging logic even applies).
      # Sorted by id ascending regardless — `Ports::Query::Ordering`'s own
      # header explains why an ask with no declared order still needs
      # this tier ("the identity tier is what makes an ask total").
      def run_filter(runtime, filter)
        aggregate_ref = filter["aggregate"].to_s
        field         = filter["field"].to_s
        op            = filter["op"].to_s
        value         = filter["value"]

        raise "unknown query comparator #{op.inspect}" unless FILTER_COMPARATORS.include?(op)

        domain_name, aggregate_name = aggregate_ref.split("::", 2)
        aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
        raise "unknown aggregate #{aggregate_ref.inspect}" unless aggregate

        clause  = QuerySpecification::Common::WhereClause.new(field: field, op: op, value: value)
        records = runtime.registry.repository(domain_name, aggregate).all
        matched = records.select do |record|
          held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(record, field))
          Ports::Query::InMemory.holds?(clause, held, {})
        end

        matched.sort_by { |record| record.id.to_s }.map { |record| { id: record.id }.merge(record.state) }
      end

      # The `refusals` entry's own "verb" column for a REFUSED ad hoc
      # filter — there is no real verb to report (a filter step carries
      # none), so this builds the SAME descriptive label kernel/cli.rs's
      # own `filter_label` builds from the same three raw fields, tolerant
      # of any of them being missing (Ruby's own nil-to-"" interpolation)
      # the same way that Rust port is.
      def filter_label(filter) = "filter #{filter["aggregate"]}.#{filter["field"]} #{filter["op"]}"
    end
  end
end
