require "fileutils"
require "tmpdir"
require_relative "isolated_boot"
require_relative "../query_specification/common/comparators"
require_relative "../query_specification/common/where_clause"
require_relative "../query_specification/field_path"
require_relative "../ports/query/in_memory"

module Hecksagain
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
      # QuerySpecification::Common::COMPARATORS (the same eight names
      # Vocabulary::QueryComparator declares, and rust/src/kernel/
      # query_comparators.rs's own ground truth), never re-typed. A
      # declared bluebook query never sees an `op:` outside this set —
      # `admits: "Vocabulary::QueryComparator"` refuses one at DECLARE
      # time — but a `"filter"`-shaped query step (below) has no
      # declare-time gate at all, so this method gates it here instead.
      FILTER_COMPARATORS = Hecksagain::QuerySpecification::Common::COMPARATORS.map(&:to_s).freeze

      def call(domain_path, steps)
        # See isolated_boot.rb's own header: resets data/ AND rebinds
        # persistence to Memory, since a Postgres-bound domain's real store
        # lives outside the copied directory and cannot be reached by
        # resetting data/ alone.
        IsolatedBoot.call(domain_path) do |copy|
          runtime = Hecks.boot(copy)

          refusals = []
          queries  = []
          fan_outs = []

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
                  queries << { query: question, rows: rows }
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
                queries << { query: question, args: args, rows: rows, reference_rows: reference }
              rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
                queries << { query: question, args: args, error: e.message }
                refusals << { verb: question, error: e.message, kind: e.class.name }
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

              # `role:` — an OPTIONAL per-step key, absent on every one of
              # the 231 existing `spec/corpus/*.json` steps (their own
              # unwrapped `runtime.dispatch` call, unchanged, so nothing
              # already pinned changes behavior). Binds the SAME ambient
              # caller `refuse_role_mismatch` reads (`Hecksagain.as_caller`,
              # `Runtime::Caller.as`) for exactly the one dispatch this
              # step makes, then unbinds — mirrors `Caller.as`'s own
              # `ensure`-restore, so back-to-back steps with different (or
              # no) `role:` never leak into each other.
              result = if step["role"]
                         Hecksagain.as_caller(role: step["role"]) { runtime.dispatch(step["verb"], **args) }
                       else
                         runtime.dispatch(step["verb"], **args)
                       end

              fan_outs.concat(fan_out_findings(runtime, fan_out_snapshot, result.events, runtime.reactions[reaction_mark..]))
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
            end
          end

          instances = {}
          runtime.registry.bluebooks.each do |domain_name, bluebook|
            bluebook.aggregates.each do |aggregate|
              runtime.registry.repository(domain_name, aggregate).all.each do |record|
                instances["#{domain_name}::#{aggregate.name}##{record.id}"] = record.state
              end
            end
          end

          events = runtime.events.map { |event| { name: event.name, aggregate: event.aggregate, id: event.id, payload: event.payload } }

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
          { instances: instances, events: events, refusals: refusals,
            reactions: runtime.reactions, sagas: runtime.sagas, saga_instances: saga_instances,
            queries: queries, fan_outs: fan_outs, bluebook: runtime.registry.bluebooks.values.first }
        end
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
      # (`Ports::Query::InMemory`, lib/hecksagain/ports/query/in_memory.rb)
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
