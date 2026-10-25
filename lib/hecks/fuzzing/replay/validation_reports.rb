module Hecks
  module Fuzzing
    module Replay
      # How a session reports what `validate` says of a command: the verdict kept beside a dry run's
      # trace, a `validate` step's refusals in the wire shape, and a refusal's offender. Mixed into
      # `Session` with `ReadOnlySteps`, whose dry runs use them.
      module ValidationReports
        private

        # What `validate` says of the same hypothetical, kept beside the trace: whether it would be
        # accepted, the stage, text and offender of its first refusal, and every refusal as
        # `[kind, stage, attribute, path, rule, class]`. It is asked through `validate_facts`, which
        # reads `to` and `with` as facts the way `dry_run?` does; `validate` would route them, and
        # so answer a different command.
        def validation_of(step, hypothetical, args)
          result = Replay.as_step_caller(step) { @runtime.validate_facts(hypothetical, **args) }
          first = result.refusals.first
          { ok: result.ok?, first_stage: first&.stage, first_message: first&.message, first_offender: offender_of(first),
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

        # A refusal's class and the attribute it is about: what `validate` keeps of a refusal that
        # names several offenders when it splits it into one refusal each.
        def offender_of(refusal)
          return unless refusal

          [refusal.class.name, refusal.respond_to?(:attribute) ? refusal.attribute : nil]
        end
      end
    end
  end
end
