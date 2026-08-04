require "fileutils"
require "tmpdir"
require_relative "isolated_boot"

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
              runtime.dispatch(step["verb"], **args)
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
    end
  end
end
