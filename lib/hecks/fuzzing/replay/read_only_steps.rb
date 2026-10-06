module Hecks
  module Fuzzing
    module Replay
      # The steps a session answers without dispatching a command: declared and ad hoc queries,
      # and dry runs. Mixed into `Session`, whose recorded lists and runtime they use.
      module ReadOnlySteps
        private

        def ask(question, args)
          return ask_filter(question) if question.is_a?(Hash)

          ask_declared(question, args)
        end

        # A `{aggregate:, field:, op:, value:}` Hash "query" step — the ad hoc
        # filter kernel/cli.rs's own object-form step also reads, bypassing the
        # declared bluebook query DSL. Answered via `Ports::Query::InMemory` directly.
        def ask_filter(question)
          rows = Replay.run_filter(@runtime, question)
          @queries << { query: question, rows: rows, instances_at: Replay.snapshot_instances(@runtime) }
        rescue StandardError => e
          @refusals << { verb: Replay.filter_label(question), error: e.message, kind: Replay.refusal_kind(e) }
        end

        # Each engine runs in its own begin/rescue, never a shared one — a shared
        # rescue would hide "one engine refused, the other didn't" (the real
        # divergence this differential oracle exists to catch) behind a plain refusal.
        #
        # Read-model asks (bare domain form, no "::") have no reference twin at all —
        # never attempted, not "attempted and agreed."
        def ask_declared(question, args)
          native_rows, native_error = native_answer(question, args)
          has_reference = question.include?("::")
          reference_rows, reference_error = reference_answer(question, args) if has_reference

          entry = { query: question, args: args, rows: native_rows, instances_at: Replay.snapshot_instances(@runtime) }
          entry[:error] = native_error.message if native_error
          add_reference(entry, reference_rows, reference_error) if has_reference
          @queries << entry

          @refusals << { verb: question, error: native_error.message, kind: Replay.refusal_kind(native_error) } if native_error
        end

        def add_reference(entry, reference_rows, reference_error)
          entry[:reference_rows]  = reference_rows
          entry[:reference_error] = reference_error.message if reference_error
        end

        def native_answer(question, args)
          [@runtime.query(question, **args), nil]
        rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
          [nil, e]
        end

        def reference_answer(question, args)
          [@runtime.reference_query(question, **args), nil]
        rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
          [nil, e]
        end

        # `dry_run` is evaluated hypothetically and recorded, never a refusal.
        # `dry_runs`' shape (`{verb:, ok:, error?:}`) is compared against
        # `kernel/cli.rs`'s own answer; `dry_run_traces` is Ruby-only oracle data.
        def dry_run(step, hypothetical, args)
          before = state_snapshot
          entry  = { verb: hypothetical }
          attempt_dry_run(entry, step, hypothetical, args)
          after = state_snapshot
          @dry_runs << entry
          @dry_run_traces << entry.merge(before: before, after: after)
        end

        def state_snapshot = { instances: Replay.snapshot_instances(@runtime), events: @runtime.events.size }

        def attempt_dry_run(entry, step, hypothetical, args)
          Replay.as_step_caller(step) { @runtime.dry_run?(hypothetical, **args) }
          entry[:ok] = true
        rescue *Runtime::DOMAIN_REFUSALS, Bluebook::Expression::EvaluationError => e
          entry.merge!(ok: false, error: e.message)
        end
      end
    end
  end
end
