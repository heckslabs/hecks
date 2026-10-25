module Hecks
  module Fuzzing
    module Replay
      # How a replay writes down a refusal: the wire shape a validation records, the tuple the
      # validation-agreement property compares, and the class and offender a dry run raised.
      module RefusalShapes
        private

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
