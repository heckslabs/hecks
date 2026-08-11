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
                refusals << { verb: question, error: e.message }
              end
              next
            end

            begin
              # `role:` — an OPTIONAL per-step key, absent on every one of
              # the 231 existing `spec/corpus/*.json` steps (their own
              # unwrapped `runtime.dispatch` call, unchanged, so nothing
              # already pinned changes behavior). Binds the SAME ambient
              # caller `refuse_role_mismatch` reads (`Hecksagain.as_caller`,
              # `Runtime::Caller.as`) for exactly the one dispatch this
              # step makes, then unbinds — mirrors `Caller.as`'s own
              # `ensure`-restore, so back-to-back steps with different (or
              # no) `role:` never leak into each other.
              if step["role"]
                Hecksagain.as_caller(role: step["role"]) { runtime.dispatch(step["verb"], **args) }
              else
                runtime.dispatch(step["verb"], **args)
              end
            rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
              refusals << { verb: step["verb"], error: e.message }
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

          # The booted chapter rides along — the boot already happened, and
          # properties.rb's lifecycle/saga checks need the declared IR
          # (state sets, handler graphs) beside the history it produced.
          # Free: no second boot, just the object the first one already
          # built.
          { instances: instances, events: events, refusals: refusals,
            reactions: runtime.reactions, sagas: runtime.sagas, queries: queries,
            bluebook: runtime.registry.bluebooks.values.first }
        end
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
