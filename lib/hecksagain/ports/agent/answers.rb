module Hecksagain
  module Ports
    module Agent
      # WHERE A RAW HASH BECOMES A STRUCT — the one place, so every
      # adapter (the real `claude_code` one, and any scripted double
      # standing in for it in a spec) is held to the identical shape.
      # An adapter's whole job ends at "here is what came back, already
      # JSON"; whether that hash is USABLE is decided once, here, not
      # re-decided per adapter.
      #
      # Every failure raises `ValidationError` — never lets a bare
      # `NoMethodError` on nil, or a `KeyError`, reach a caller looking
      # for an agent-shaped failure. `bin/interview` catches exactly one
      # class for "the model answered badly," not a grab-bag of Ruby's
      # own.
      module Answers
        VERB_PATTERN = /\A[A-Za-z]+::[A-Za-z]+\.[A-Za-z]+\z/

        module_function

        def questions(raw)
          rows(raw, "questions").map { |row| Question.new(text: text!(row, "text"), because: text!(row, "because")) }
        end

        def proposals(raw)
          rows(raw, "proposals").map do |row|
            Proposal.new(verb: verb!(row), rationale: text!(row, "rationale"), arguments: arguments!(row))
          end
        end

        def findings(raw)
          rows(raw, "findings").map do |row|
            Finding.new(kind: kind!(row), severity: severity!(row), subject: text!(row, "subject"),
                        message: text!(row, "message"))
          end
        end

        def suggestions(raw)
          rows(raw, "names").map do |row|
            Suggestion.new(name: text!(row, "name"), because: text!(row, "because"),
                            rejected: Array(row["rejected"]).map(&:to_s))
          end
        end

        # ── shared checks, each named for what it refuses ───────────────

        def rows(raw, key)
          raise ValidationError, "expected a Hash back, got #{raw.class}: #{raw.inspect}" unless raw.is_a?(Hash)

          value = raw[key]
          return value if value.is_a?(Array)

          raise ValidationError, "no #{key.inspect} array in the answer: #{raw.inspect}"
        end

        def text!(row, key)
          value = row[key]
          return value.to_s if value && !value.to_s.strip.empty?

          raise ValidationError, "#{key.inspect} missing or blank in #{row.inspect}"
        end

        # A VERB THE LANGUAGE COULD NOT EVEN PARSE IS AN ADAPTER FAULT,
        # refused right here — the same `not_fully_qualified` shape the
        # language's own grammar already refuses by, reused rather than
        # reinvented. A verb naming a real category that turns out to
        # describe the wrong fact is NOT this port's business: that one
        # dispatches, and `Interview::Session#offer` is what says no.
        def verb!(row)
          verb = row["verb"].to_s
          return verb if VERB_PATTERN.match?(verb)

          raise ValidationError, "#{verb.inspect} is not a fully-qualified verb (Chapter::Aggregate.Command)"
        end

        def kind!(row)
          kind = row["kind"].to_s.to_sym
          return kind if CRITIQUE_KINDS.include?(kind)

          raise ValidationError, "#{kind.inspect} is not a critique kind this port knows (#{CRITIQUE_KINDS.join(', ')})"
        end

        def severity!(row)
          severity = row["severity"].to_s.to_sym
          return severity if SEVERITIES.include?(severity)

          raise ValidationError, "#{severity.inspect} is not a severity this port knows (#{SEVERITIES.join(', ')})"
        end

        # ROWS SHAPED EXACTLY AS `Interview::Proposal::Argument` — a
        # reference's `field` is legitimately blank (a reference IS an
        # id), so only `name` is required here.
        def arguments!(row)
          Array(row["arguments"]).map do |argument|
            name = argument["name"].to_s
            raise ValidationError, "argument row has no name: #{argument.inspect}" if name.empty?

            { name: name, field: argument["field"].to_s, value: argument["value"].to_s }
          end
        end
      end
    end
  end
end
