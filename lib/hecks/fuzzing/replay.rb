require "fileutils"
require "tmpdir"
require_relative "isolated_boot"
require_relative "self_consistency"
require_relative "../query_specification/common/comparators"
require_relative "../query_specification/common/where_clause"
require_relative "../query_specification/field_path"
require_relative "../ports/query/in_memory"

module Hecks
  module Fuzzing
    # Replays a step list in-process against a fresh boot, returning the
    # observable history as data instead of JSON on stdout.
    module Replay
      module_function

      # Mirrors QuerySpecification::Common::COMPARATORS, not the Rust
      # kernel's own comparator enum, which is missing `none_in_state` and has drifted.
      FILTER_COMPARATORS = Hecks::QuerySpecification::Common::COMPARATORS.map(&:to_s).freeze

      # The two classes Admissibility#enforce_givens/#enforce_lifecycle_guard raise;
      # any other DOMAIN_REFUSAL proves the guard itself did not fire.
      GUARD_REFUSAL_CLASSES = [Runtime::GivenNotMet, Runtime::LifecycleRefused].freeze

      # Replays +steps+ against a fresh boot of +domain_path+. The oracle snapshots taken
      # inside the loop are timed relative to dispatch; do not reorder them.
      #
      # @param domain_path [String] filesystem path to the domain directory to replay
      # @param adapter [Symbol] persistence adapter to boot the copy with
      # @param database [String, nil] PostgresEra database name (required for :postgres_era)
      # @param self_consistency [Boolean] also run SelfConsistency.check before returning
      # @return [Hash] instances, events, refusals, reactions, sagas, queries, oracle traces
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/MethodLength
      # rubocop:disable-next Metrics/PerceivedComplexity
      def call(domain_path, steps, adapter: :memory, database: nil, schema: nil, self_consistency: false)
        # See isolated_boot.rb's own header: resets data/ and rebinds persistence to the
        # chosen adapter, since a Postgres-bound domain's real store lives outside the
        # copied directory and can't be reached by resetting data/ alone.
        IsolatedBoot.call(domain_path, adapter: adapter, database: database, schema: schema) do |copy|
          runtime = Hecks.boot(copy)

          refusals        = []
          queries         = []
          dry_runs        = []
          dry_run_traces  = []
          fan_outs        = []
          guard_checks    = []
          mutation_traces = []
          outbox_traces   = []

          # Every `[domain, aggregate_name]` a `for_each` policy could query, resolved
          # once from every loaded bluebook's own fanning-out policies. Empty when no
          # domain declares `for_each`, so the snapshot below costs nothing until one does.
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
              # A `{aggregate:, field:, op:, value:}` Hash "query" step — the ad hoc
              # filter kernel/cli.rs's own object-form step also reads, bypassing the
              # declared bluebook query DSL. Answered via `Ports::Query::InMemory` directly.
              if question.is_a?(Hash)
                begin
                  rows = run_filter(runtime, question)
                  queries << { query: question, rows: rows, instances_at: snapshot_instances(runtime) }
                rescue StandardError => e
                  refusals << { verb: filter_label(question), error: e.message, kind: refusal_kind(e) }
                end
                next
              end

              # Each engine runs in its own begin/rescue, never a shared one — a shared
              # rescue would hide "one engine refused, the other didn't" (the real
              # divergence this differential oracle exists to catch) behind a plain refusal.
              native_rows = native_error = nil
              begin
                native_rows = runtime.query(question, **args)
              rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
                native_error = e
              end

              # Read-model asks (bare domain form, no "::") have no
              # reference twin at all — never attempted, not "attempted and
              # agreed."
              has_reference = question.include?("::")
              reference_rows = reference_error = nil
              if has_reference
                begin
                  reference_rows = runtime.reference_query(question, **args)
                rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
                  reference_error = e
                end
              end

              entry = { query: question, args: args, rows: native_rows, instances_at: snapshot_instances(runtime) }
              entry[:error] = native_error.message if native_error
              if has_reference
                entry[:reference_rows]  = reference_rows
                entry[:reference_error] = reference_error.message if reference_error
              end
              queries << entry

              refusals << { verb: question, error: native_error.message, kind: refusal_kind(native_error) } if native_error
              next
            end

            # `dry_run` is evaluated hypothetically and recorded, never a refusal.
            # `dry_runs`' shape (`{verb:, ok:, error?:}`) is compared against
            # `kernel/cli.rs`'s own answer; `dry_run_traces` is Ruby-only oracle data.
            if (hypothetical = step["dry_run"])
              before = { instances: snapshot_instances(runtime), events: runtime.events.size }
              entry  = { verb: hypothetical }
              begin
                as_step_caller(step) { runtime.dry_run?(hypothetical, **args) }
                entry[:ok] = true
              rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
                entry.merge!(ok: false, error: e.message)
              end
              after = { instances: snapshot_instances(runtime), events: runtime.events.size }
              dry_runs << entry
              dry_run_traces << entry.merge(before: before, after: after)
              next
            end

            begin
              # Taken before dispatch, so this step's own reactions can be sliced out
              # after and matched against an independent recomputation of what a
              # `for_each` policy should have fanned out over.
              reaction_mark = runtime.reactions.size

              # `saga_log_mark` slices `runtime.sagas` the same way `reaction_mark`
              # slices `runtime.reactions`. `outbox_before_ids` is a set of delivery_ids,
              # not a size, because `runtime.outbox.rows` concatenates several stores'
              # own arrays, so a plain "grew from N to M" tail slice could miss or
              # misattribute rows once more than one repository has an outbox.
              saga_log_mark      = runtime.sagas.size
              outbox_before_ids  = runtime.outbox.rows.map(&:delivery_id)

              # The snapshot a `for_each` query would have seen, taken before dispatch:
              # `deliver_for_each` runs its query synchronously inside this same
              # dispatch, so reading the live repository after would see what the
              # fan-out's own dispatched commands already mutated, not what it matched.
              fan_out_snapshot = fan_out_targets.each_with_object({}) do |((fdomain, faggregate_name), aggregate), snap|
                next unless aggregate

                snap[[fdomain, faggregate_name]] =
                  runtime.registry.repository(fdomain, aggregate).all.to_h { |record| [record.id, record.state.dup] }
              end

              # Same idiom as fan_out_snapshot above: the guard is replayed read-only
              # before this step's real dispatch can mutate anything a cross-aggregate
              # given dereferences.
              guard_check = build_guard_check(runtime, step["verb"], args)

              # Same idiom again: the entity element a mutation step's args address is
              # snapshotted before dispatch, so it can be diffed against its post-dispatch state.
              mutation_trace = build_mutation_trace(runtime, step["verb"], args)

              # `role:`/`actor_id:` are optional per-step keys; a step with neither
              # dispatches bare, as every existing corpus step always has. Binds the
              # ambient caller for exactly this one dispatch, then unbinds, so
              # back-to-back steps with different (or no) `role:` never leak into each other.
              result = as_step_caller(step) { runtime.dispatch_flat(step["verb"], args) }

              fan_outs.concat(fan_out_findings(runtime, fan_out_snapshot, result.events, runtime.reactions[reaction_mark..]))

              # Every outbox row this step's own dispatch newly wrote, across every
              # bound repository including any a reaction cascade touched, paired with
              # the reaction/saga rows that same dispatch produced. Skipped when empty.
              outbox_new_rows = runtime.outbox.rows.reject { |row| outbox_before_ids.include?(row.delivery_id) }
              if outbox_new_rows.any?
                outbox_traces << { verb: step["verb"], rows: outbox_new_rows.map(&:to_h),
                                    reactions: runtime.reactions[reaction_mark..].dup,
                                    sagas: runtime.sagas[saga_log_mark..].dup }
              end

              guard_checks << guard_check.merge(actual_refused: false, actual_kind: nil) if guard_check
              # After — only on success ; a refused step mutated nothing,
              # so there is no "after" to compare (and #build_mutation_
              # trace already skipped anything with no mutations to
              # trace in the first place).
              mutation_traces << mutation_trace.merge(after: read_mutation_after(runtime, mutation_trace)) if mutation_trace
            rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
              # `kind:` is the raised class, not derived from the message: several
              # refusal templates share the same wording, so only the class tells a
              # guard refusal apart from the rest.
              refusals << { verb: step["verb"], error: e.message, kind: refusal_kind(e) }
              # Only a refusal raised by the guard itself counts here. A refusal from a
              # stage before or after enforce_givens can share TypeMismatch's class, so
              # anything outside the two guard classes is left out — inconclusive, not a pass.
              if guard_check && GUARD_REFUSAL_CLASSES.include?(e.class)
                guard_checks << guard_check.merge(actual_refused: true,
                                                  actual_kind:    e.class.name)
              end
            end
          end

          instances = snapshot_instances(runtime)

          events = runtime.events.map do |event|
            { name: event.name, aggregate: event.aggregate, id: event.id, payload: event.payload }
          end

          # The live process-manager store, materialised to inert data (`{ pm_name =>
          # { correlation => { state:, memory: } } }`), captured here because the
          # runtime goes out of scope with the boot and the Memory rebind leaves no
          # real saga store for Properties.sagas_rehydrate_cleanly to read otherwise.
          saga_instances = runtime.registry.saga_instances.each_with_object({}) do |(pm_name, conversations), out|
            out[pm_name] = conversations.each_with_object({}) do |(correlation, instance), rows|
              rows[correlation] = { state: instance[:state], memory: Runtime::Value.materialize(instance[:memory]) }
            end
          end

          # The booted chapter rides along so properties.rb's lifecycle/saga checks
          # have the declared IR beside the history it produced. `bluebook:` (singular)
          # is the first-loaded chapter, kept for properties scoped to it deliberately;
          # `bluebooks:` (plural) is the full domain-name-keyed map, for a property that
          # needs to resolve a verb back to its own declaring bluebook.
          history = { instances: instances, events: events, refusals: refusals,
                      reactions: runtime.reactions, sagas: runtime.sagas, saga_instances: saga_instances,
                      queries: queries, dry_runs: dry_runs, dry_run_traces: dry_run_traces,
                      fan_outs: fan_outs, guard_checks: guard_checks,
                      mutation_traces: mutation_traces, outbox_traces: outbox_traces,
                      saga_dispatches: runtime.saga_dispatches, policy_dispatches: runtime.policy_dispatches,
                      bluebook: runtime.registry.bluebooks.values.first,
                      bluebooks: runtime.registry.bluebooks.dup }

          # `runtime` is still live here — the one and only place it is — so
          # SelfConsistency runs now, against the same registry a second boot couldn't reuse.
          history[:self_consistency] = SelfConsistency.check(runtime, history) if self_consistency

          history
        end
      end

      # Runs the block with this step's `role:`/`actor_id:` bound as the ambient
      # caller, if it declares one; a step with no `role:` dispatches bare.
      def as_step_caller(step, &)
        return yield unless step["role"]

        Hecks.as_caller(role: step["role"], actor_id: step["actor_id"], &)
      end

      # Every persisted record's state, keyed by `"Domain::Aggregate#id"`. Called once
      # per query step, not only at the end, so a property recomputing "the eligible
      # rows" reads the state as that query actually saw it, not a shared final one.
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

      # Resolves the record (if any) this step's guard should be checked against, and
      # replays enforce_givens then admissible_transition, in that order, to mirror
      # the real DISPATCH_ORDER. `nil` for anything out of scope.
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/PerceivedComplexity
      def build_guard_check(runtime, verb, args)
        domain_name, aggregate_name, command_name = Naming.split_verb(verb)
        return nil unless command_name && !command_name.include?(".")

        aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
        command   = aggregate&.command(command_name)
        return nil unless aggregate && command && !command.creates?

        # A transition-only guard (no per-command `from:`/`given`, only an aggregate
        # `lifecycle` block naming this command) still counts as something to check,
        # now that `admissible_transition` is reproduced below.
        has_transition = aggregate.lifecycle&.transitions_for(command.hecks_name)&.any?
        return nil if command.givens.empty? && !command.from && !has_transition

        reference_key = command.references.to_s.empty? ? nil : Naming.reference_key(command.references)
        id = Runtime::Identity.of(aggregate, args) ||
             Runtime::Identity.from(aggregate, args, :id) ||
             (reference_key && Runtime::Identity.from(aggregate, args, reference_key))
        return nil unless id

        record = runtime.registry.repository(domain_name, aggregate).find(id)
        return nil unless record

        rules = Runtime::CommandRules.new(runtime.registry)
        # Real dispatch normalizes args (step_normalize_args) before it ever reaches
        # enforce_givens, coercing a bare scalar like "white" into its command's declared
        # value-object shape. Skipping that here would hand enforce_givens the raw fuzzed
        # shape instead, and a `given` comparing a normalized field against it would walk a
        # path a String happens to answer (a substring lookup) rather than the refusal real
        # dispatch raises. `send` reaches the interpreter's own private coercion (the same
        # idiom SelfConsistency#last_advancing_event uses for `saga_correlation`) rather than
        # reimplementing it here.
        interpreter = Runtime::CommandInterpreter.new(runtime.registry, rules: rules)
        normalized_args = interpreter.send(:normalize_args, aggregate, command, args)
        recomputed_kind = begin
          rules.enforce_givens(record.dup, command, normalized_args, domain: domain_name, declaring: aggregate)

          # A second, separate DISPATCH_ORDER step: the aggregate's own `lifecycle`
          # transition guard is a wholly different method from enforce_givens' own
          # per-command `from:` check, called only when enforce_givens didn't already refuse.
          # It reads only the record's own lifecycle field and the command's declared
          # transitions, never `args`, so it needs no normalized input of its own.
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

      # Scoped to entity-dispatched commands only, the one place `append`/`remove`/
      # `multiply`/`clamp` act on an entity's own attributes. `nil` for anything out of
      # scope: an aggregate-level command, no mutations, or unresolvable identity args.
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/PerceivedComplexity
      def build_mutation_trace(runtime, verb, args)
        domain_name, aggregate_name, command_name = Naming.split_verb(verb)
        return nil unless command_name&.include?(".")

        aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
        return nil unless aggregate

        entity_name, entity_command_name = command_name.split(".", 2)
        entity  = aggregate.entities.find { |candidate| candidate.hecks_name == entity_name }
        command = entity&.command(entity_command_name)
        return nil unless command&.mutations&.any?

        # Same idiom as build_guard_check above: real dispatch normalizes args
        # (step_normalize_args) before apply_mutations ever runs, coercing a declared
        # payload attribute into its command's shape — a composite argument's own
        # `Value.build` fills that shape's declared defaults along the way. Recomputing
        # a mutation against the raw fuzzed args instead would disagree with real
        # dispatch whenever a caller omitted a defaulted field, the same false-divergence
        # shape build_guard_check guards against for the guard check.
        args = Runtime::CommandInterpreter.new(runtime.registry, rules: Runtime::CommandRules.new(runtime.registry))
                                          .send(:normalize_args, aggregate, command, args)

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

      # Re-locates the same element by identity, not position, since a mutation could
      # have changed the array's own length or order. `nil` if it vanished.
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

      # One finding per (event, for_each policy) pair, independent of
      # `PolicyInterpreter#deliver_for_each`, answered via `Ports::Query::InMemory`
      # directly rather than `QueryInterpreter`, so this stays blind to nothing the
      # fan-out feature adds. `expected_row_ids` is `nil` when `where` did not hold.
      def fan_out_findings(runtime, snapshot, announced, reactions_since)
        announced.each_with_object([]) do |event, findings|
          # `event.aggregate` is domain-qualified ("Banking::Account"); split the same
          # two ways `PolicyInterpreter#policies_for` does.
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

      # Builds one fan-out finding, comparing one `for_each` policy's independently
      # recomputed expected rows against what actually reacted for one event.
      def fan_out_finding(runtime, snapshot, policy, event, domain, reactions_since)
        payload = event.payload.transform_keys(&:to_sym)
        held = policy.where.to_s.empty? ||
               Bluebook::Expression::Evaluator.call(policy.where, {}, payload)

        expected = held ? expected_fan_out_rows(runtime, snapshot, policy, domain, payload) : nil

        actual = reactions_since.select { |r| r[:policy] == policy.name && r[:on] == event.name }
                                .filter_map { |r| r[:for_row] }

        { policy: policy.name, on: event.name, expected_row_ids: expected, actual_row_ids: actual }
      end

      # `policy.for_each`'s declared query, answered against the pre-dispatch snapshot
      # (the real fan-out's query runs before its own dispatched commands can mutate
      # anything it would match, so this must read the same "before" state). A `Symbol`
      # where-value binds to the triggering event's own payload; a literal is compared as declared.
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

      # Names the outcome class a recorded refusal row should carry: an evaluation
      # fault is `"Fault"` (matching the Rust kernel's `Refusal::Fault`), never a raw
      # Ruby exception name.
      def refusal_kind(error)
        error.is_a?(Bluebook::Expression::EvaluationError) ? "Fault" : error.class.name
      end

      # Answers one ad hoc filter step, the mirror image of kernel/cli.rs's own
      # `run_filter`, calling the same production `Ports::Query::InMemory` rather than
      # re-deriving comparator behavior by hand. Sorted by id ascending regardless,
      # since an ad hoc filter declares no order of its own.
      #
      # @raise [Bluebook::Expression::EvaluationError] if `op` or `"aggregate"` is unknown
      def run_filter(runtime, filter)
        aggregate_ref = filter["aggregate"].to_s
        field         = filter["field"].to_s
        op            = filter["op"].to_s
        value         = filter["value"]

        # A malformed ad-hoc ask is a fault (C8.3), not a bare RuntimeError.
        unless FILTER_COMPARATORS.include?(op)
          raise Bluebook::Expression::EvaluationError, "unknown query comparator #{op.inspect}"
        end

        domain_name, aggregate_name = aggregate_ref.split("::", 2)
        aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
        raise Bluebook::Expression::EvaluationError, "unknown aggregate #{aggregate_ref.inspect}" unless aggregate

        clause  = QuerySpecification::Common::WhereClause.new(field: field, op: op, value: value)
        records = runtime.registry.repository(domain_name, aggregate).all
        matched = records.select do |record|
          held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(record, field))
          Ports::Query::InMemory.holds?(clause, held, {})
        end

        matched.sort_by { |record| record.id.to_s }.map { |record| { id: record.id }.merge(record.state) }
      end

      # Builds the `refusals` entry's own "verb" column for a refused ad hoc filter,
      # which carries no real verb to report.
      def filter_label(filter) = "filter #{filter['aggregate']}.#{filter['field']} #{filter['op']}"
    end
  end
end
