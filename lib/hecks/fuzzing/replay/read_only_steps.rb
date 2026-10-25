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
          add_pages(entry, question, args) unless native_error
          add_reference(entry, reference_rows, reference_error) if has_reference
          @queries << entry

          @refusals << { verb: question, error: native_error.message, kind: Replay.refusal_kind(native_error) } if native_error
        end

        # A cursor query's walks, taken for `Properties` to hold to the unpaged rows.
        def add_pages(entry, question, args)
          entry[:pages] = cursor_walks(question, args) if cursor_query?(question)
        end

        # Whether `question` names a declared aggregate query that pages by cursor.
        def cursor_query?(question)
          domain, aggregate_name, query_name = Naming.split_verb(question)
          declared = @runtime.bluebooks[domain]&.aggregate(aggregate_name)
          !declared&.query(query_name.to_s)&.cursor.nil?
        end

        # Every page of a cursor query, walked at the query's own page size and again one row at
        # a time (so a boundary falls between any two rows), as `{ page_size:, pages: }` per
        # walk. A walk starts at the first page whatever `after` the ask itself carried.
        def cursor_walks(question, args)
          from_start = args.except(:after)
          [nil, 1].map { |size| { page_size: size, pages: walk_pages(question, from_start, size) } }
        end

        def walk_pages(question, args, size)
          pages = []
          after = nil
          loop do
            page = @runtime.query_page(question, after: after, page_size: size, **args)
            pages << page.fetch(:rows)
            break unless (after = page[:after])
          end
          pages
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
          @dry_run_traces << entry.merge(before: before, after: after, validation: validation_of(step, hypothetical, args))
        end

        # What `validate` says of the same hypothetical, kept beside the trace: whether it would be
        # accepted, the stage and text of its first refusal, and every refusal as `[kind, stage,
        # attribute, path, rule, class]`.
        def validation_of(step, hypothetical, args)
          result = Replay.as_step_caller(step) { @runtime.validate(hypothetical, args) }
          first = result.refusals.first
          { ok: result.ok?, first_stage: first&.stage, first_message: first&.message,
            reasons: result.refusals.map { |refusal| reason_of(refusal) } }
        rescue Runtime::WiringError
          nil
        end

        # A `validate` step: every refusal the command would meet, recorded as data and never as a
        # refusal of the script. Compared against `kernel/cli.rs`'s own `validate` answer.
        def validate_step(step, hypothetical, args)
          result = Replay.as_step_caller(step) { @runtime.validate(hypothetical, args) }
          @validations << { verb: hypothetical, ok: result.ok?,
                            refusals: result.refusals.map { |refusal| validation_entry(refusal) } }
        end

        # One refusal in the wire shape: class, kind, stage, attribute, path, rule and message.
        def validation_entry(refusal)
          detail = refusal.to_h
          { kind: detail[:kind], stage: detail[:stage], refusal: class_name_of(refusal),
            attribute: detail[:attribute], path: detail[:path], rule: detail[:rule], message: detail[:message] }
        end

        # One refusal as the comparison reads it: `[kind, stage, attribute, path, rule, class]`.
        def reason_of(refusal)
          entry = validation_entry(refusal)
          parts = entry.values_at(:kind, :stage, :attribute, :path, :rule)
          [*parts.map { |part| part&.to_s }, entry[:refusal]]
        end

        def class_name_of(refusal)
          name = refusal.class.name
          name.split("::").last
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
