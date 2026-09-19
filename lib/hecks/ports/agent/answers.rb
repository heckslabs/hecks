module Hecks
  module Ports
    module Agent
      # Where a raw hash becomes a struct — the one place, so every
      # adapter (the real `claude_code` one, and any scripted double
      # standing in for it in a spec) is held to the identical shape.
      # An adapter's whole job ends at "here is what came back, already
      # JSON"; whether that hash is usable is decided once, here, not
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

        # Validates an adapter's raw answer to `ask` into `Question` structs.
        #
        # @param raw [Hash{String => Object}] the adapter's parsed reply, expected to hold a
        #   `"questions"` array of `{"text" =>, "because" =>}` rows; any other shape is refused
        # @return [Array<Ports::Agent::Question>] one struct per row, in the answer's order;
        #   `[]` for an empty `"questions"` array
        # @raise [Ports::Agent::ValidationError] if `raw` is not a Hash, holds no
        #   `"questions"` array, or a row's `"text"` or `"because"` is missing or blank
        def questions(raw)
          rows(raw, "questions").map { |row| Question.new(text: text!(row, "text"), because: text!(row, "because")) }
        end

        # Validates an adapter's raw answer to `interpret` into `Proposal` structs.
        #
        # @param raw [Hash{String => Object}] the adapter's parsed reply, expected to hold a
        #   `"proposals"` array of `{"verb" =>, "rationale" =>, "arguments" =>}` rows
        # @return [Array<Ports::Agent::Proposal>] one struct per row, its `arguments` an Array
        #   of `{name:, field:, value:}` Hashes (see `arguments!`); `[]` for an empty
        #   `"proposals"` array
        # @raise [Ports::Agent::ValidationError] if `raw` is not a Hash, holds no
        #   `"proposals"` array, or a row has a verb that is not fully qualified, a blank
        #   `"rationale"`, or an argument row with no `"name"`
        def proposals(raw)
          rows(raw, "proposals").map do |row|
            Proposal.new(verb: verb!(row), rationale: text!(row, "rationale"), arguments: arguments!(row))
          end
        end

        # Validates an adapter's raw answer to `critique` into `Finding` structs.
        #
        # @param raw [Hash{String => Object}] the adapter's parsed reply, expected to hold a
        #   `"findings"` array of `{"kind" =>, "severity" =>, "subject" =>, "message" =>}` rows
        # @return [Array<Ports::Agent::Finding>] one struct per row, with `kind` and `severity`
        #   as Symbols; `[]` for an empty `"findings"` array
        # @raise [Ports::Agent::ValidationError] if `raw` is not a Hash, holds no
        #   `"findings"` array, or a row's kind is outside `CRITIQUE_KINDS`, its severity is
        #   outside `SEVERITIES`, or its `"subject"` or `"message"` is missing or blank
        def findings(raw)
          rows(raw, "findings").map do |row|
            Finding.new(kind: kind!(row), severity: severity!(row), subject: text!(row, "subject"),
                        message: text!(row, "message"))
          end
        end

        # Validates an adapter's raw answer to `suggest_name` into `Suggestion` structs.
        #
        # @param raw [Hash{String => Object}] the adapter's parsed reply, expected to hold a
        #   `"names"` array of `{"name" =>, "because" =>, "rejected" =>}` rows
        # @return [Array<Ports::Agent::Suggestion>] one struct per row, its `rejected` an
        #   Array of Strings (`[]` when the row carries none); `[]` for an empty `"names"` array
        # @raise [Ports::Agent::ValidationError] if `raw` is not a Hash, holds no `"names"`
        #   array, or a row's `"name"` or `"because"` is missing or blank
        def suggestions(raw)
          rows(raw, "names").map do |row|
            Suggestion.new(name: text!(row, "name"), because: text!(row, "because"),
                           rejected: Array(row["rejected"]).map(&:to_s))
          end
        end

        # ── shared checks, each named for what it refuses ───────────────

        # Reads the array of rows an answer holds under one key, refusing any other shape.
        #
        # @param raw [Object] the adapter's reply; only a Hash is accepted
        # @param key [String] the key the rows sit under, such as `"questions"`
        # @return [Array<Object>] the rows exactly as the adapter gave them, unvalidated
        # @raise [Ports::Agent::ValidationError] if `raw` is not a Hash, or `raw[key]` is
        #   not an Array
        def rows(raw, key)
          raise ValidationError, "expected a Hash back, got #{raw.class}: #{raw.inspect}" unless raw.is_a?(Hash)

          value = raw[key]
          return value if value.is_a?(Array)

          raise ValidationError, "no #{key.inspect} array in the answer: #{raw.inspect}"
        end

        # Reads one required text field off a row, refusing a missing or blank one.
        #
        # @param row [Hash{String => Object}] one row of the adapter's answer
        # @param key [String] the field to read, such as `"because"`
        # @return [String] the field's value as a String, whitespace untouched
        # @raise [Ports::Agent::ValidationError] if the field is nil, false, empty, or only
        #   whitespace
        def text!(row, key)
          value = row[key]
          return value.to_s if value && !value.to_s.strip.empty?

          raise ValidationError, "#{key.inspect} missing or blank in #{row.inspect}"
        end

        # Reads a proposal row's verb, refusing one that is not fully qualified.
        #
        # A verb the language could not even parse is an adapter fault,
        # refused right here — the same `not_fully_qualified` shape the
        # language's own grammar already refuses by, reused rather than
        # reinvented. A verb naming a real category that turns out to
        # describe the wrong fact is not this port's business: that one
        # dispatches, and `Interview::Session#offer` is what says no.
        #
        # @param row [Hash{String => Object}] one proposal row of the adapter's answer
        # @return [String] the row's `"verb"`, shaped `Chapter::Aggregate.Command`
        # @raise [Ports::Agent::ValidationError] if the verb is missing or does not match
        #   `VERB_PATTERN`
        def verb!(row)
          verb = row["verb"].to_s
          return verb if VERB_PATTERN.match?(verb)

          raise ValidationError, "#{verb.inspect} is not a fully-qualified verb (Chapter::Aggregate.Command)"
        end

        # Reads a finding row's kind, refusing one outside the closed critique vocabulary.
        #
        # @param row [Hash{String => Object}] one finding row of the adapter's answer
        # @return [Symbol] the row's `"kind"`, a member of `CRITIQUE_KINDS`
        # @raise [Ports::Agent::ValidationError] if the kind is missing or not in
        #   `CRITIQUE_KINDS`
        def kind!(row)
          kind = row["kind"].to_s.to_sym
          return kind if CRITIQUE_KINDS.include?(kind)

          raise ValidationError, "#{kind.inspect} is not a critique kind this port knows (#{CRITIQUE_KINDS.join(', ')})"
        end

        # Reads a finding row's severity, refusing anything but the two that exist.
        #
        # @param row [Hash{String => Object}] one finding row of the adapter's answer
        # @return [Symbol] the row's `"severity"`, a member of `SEVERITIES`
        # @raise [Ports::Agent::ValidationError] if the severity is missing or not in
        #   `SEVERITIES`
        def severity!(row)
          severity = row["severity"].to_s.to_sym
          return severity if SEVERITIES.include?(severity)

          raise ValidationError, "#{severity.inspect} is not a severity this port knows (#{SEVERITIES.join(', ')})"
        end

        # Normalises a proposal row's arguments into symbol-keyed, all-String rows.
        #
        # Rows shaped exactly as `Interview::Proposal::Argument` — a
        # reference's `field` is legitimately blank (a reference is an
        # id), so only `name` is required here.
        #
        # @param row [Hash{String => Object}] one proposal row of the adapter's answer
        # @return [Array<Hash{Symbol => String}>] one `{name:, field:, value:}` Hash per
        #   argument, `field` and `value` being `""` when absent; `[]` when the row has no
        #   `"arguments"`
        # @raise [Ports::Agent::ValidationError] if an argument row's `"name"` is missing or
        #   empty
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
