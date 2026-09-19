require_relative "../../naming"
require_relative "../statements"

module Hecks
  module Projections
    module Glossary
      # Every sentence the glossary says, and the rule each one obeys.
      #
      # Authored text is verbatim: an aggregate's `description`, a
      # command's `goal`, a query's `description`, an invariant's own
      # words. Derived text is mechanical, from one declared fact, in a
      # shape a reader outside engineering would say — "Recorded after
      # Freeze account", "Made up of an amount (a whole number) and a
      # currency (text)". Nothing is paraphrased and nothing is guessed:
      # a fact with no honest plain phrasing gets no sentence (the
      # `DocsProjector` rule — a wrong sentence is worse than none).
      #
      # Cross-references come only from declared structure (a command's
      # `emits:`, a policy's `on`/`trigger`), resolved through the
      # document's `Index`; free prose is never searched for words to
      # link. A reference the chapter does not declare (a cross-domain
      # command) is spoken as plain words.
      module Sentences
        TYPE_WORDS = {
          "Integer" => "a whole number", "Float" => "a number", "String" => "text",
          "Boolean" => "yes or no", "TrueClass" => "yes or no", "FalseClass" => "yes or no"
        }.freeze

        module_function

        # The paragraphs under a term's headword — the definition first,
        # then, when the term carries rules, one "Always true: …" line.
        #
        # @param entry [Glossary::Entry] the term to render
        # @param index [Glossary::Index] the document's link index
        # @return [Array<String>] one or more paragraphs, compacted of any that
        #   have nothing to say (such as an entity with no lifecycle)
        def paragraphs(entry, index)
          facts = entry.facts
          case entry.kind
          when :entity       then holder_paragraphs(facts[:entity])
          when :value_object then value_object_paragraphs(facts[:value_object], index, entry.within)
          when :command      then [command_sentence(facts[:command])]
          when :query        then [facts[:query].description]
          when :event        then [event_sentence(facts, index)]
          when :policy       then [policy_sentence(facts[:policy], index)]
          when :saga         then [saga_sentence(facts[:saga], index)]
          when :role         then [role_sentence(facts[:commands], index)]
          when :read_model   then [facts[:read_model].description]
          end.compact
        end

        # An aggregate's lede or an entity's entry: what it is, then the
        # states it can be in.
        #
        # @param holder [Bluebook::Aggregate, Bluebook::Entity] the holder to describe
        # @return [Array<String>] `holder`'s description, then its lifecycle sentence;
        #   either or both may be absent
        def holder_paragraphs(holder)
          [holder.description, holder.lifecycle && lifecycle_sentence(holder.lifecycle)].compact
        end

        # Describes a lifecycle's starting state and every state it can reach.
        #
        # @param lifecycle [Bluebook::Lifecycle] the state machine to describe
        # @return [String] what state it starts in and every state it can reach
        def lifecycle_sentence(lifecycle)
          states = ([lifecycle.default] + lifecycle.transitions.map { |_name, transition| transition.target }).uniq
          "Starts out #{spoken(lifecycle.default)}. " \
            "Can be #{Naming.to_sentence_list(states.map { |state| spoken(state) }, conj: 'or')}."
        end

        # A state name is spelled `awaiting_credit`; said, it is "awaiting credit".
        #
        # @param state [String, Symbol] a state name
        # @return [String] `state` with underscores turned to spaces
        def spoken(state) = state.to_s.tr("_", " ")

        # Renders a value object's definition, and its rules if it has any.
        #
        # @param value_object [Bluebook::ValueObject] the value object to describe
        # @param index [Glossary::Index] the document's link index
        # @param within [String, nil] the value object's own holder's name, for
        #   resolving a nested value object's own type link
        # @return [Array<String>] the value object's definition sentence, then its
        #   "Always true: …" rules line; the rules line is absent when it has none
        def value_object_paragraphs(value_object, index, within)
          rules = value_object.invariants.map { |invariant| Statements.invariant_statement(invariant) }
          [value_object_sentence(value_object, index, within), rules_line(rules)].compact
        end

        # A one-field object whose field is just "value" is its type —
        # "Text.", "A whole number." — the field name would add nothing.
        #
        # @param value_object [Bluebook::ValueObject] the value object to describe
        # @param index [Glossary::Index] the document's link index
        # @param within [String, nil] the value object's own holder's name
        # @return [String] the value object's definition sentence
        def value_object_sentence(value_object, index, within)
          return closed_set_sentence(value_object.members) if value_object.closed_set?
          return "A marker with no details of its own." if value_object.attributes.empty?

          only = value_object.attributes.first
          if value_object.attributes.size == 1 && only.name.to_s == "value"
            return "#{upper_first(type_words(only, index, within))}."
          end

          fields = value_object.attributes.map { |field| field_phrase(field, index, within) }
          "Made up of #{Naming.to_sentence_list(fields)}."
        end

        # "amount (a whole number)" — the field as the author named it,
        # then what kind of thing goes in it.
        #
        # @param field [Bluebook::Attribute] the field to describe
        # @param index [Glossary::Index] the document's link index
        # @param within [String, nil] the field's own holder's name
        # @return [String] the field's name, spoken, with its type in parentheses
        def field_phrase(field, index, within)
          "#{Naming.words(field.name).downcase} (#{type_words(field, index, within)})"
        end

        # Describes one field's type in plain words.
        #
        # @param field [Bluebook::Attribute] the field to describe
        # @param index [Glossary::Index] the document's link index
        # @param within [String, nil] the field's own holder's name
        # @return [String] the field's type in plain words, or a link to its value
        #   object's own headword; "a list of …" when the field is a list
        def type_words(field, index, within)
          type  = field.type.to_s
          inner = TYPE_WORDS[type] || index.link(:value_object, type, within: within)
          field.list? ? "a list of #{inner}" : inner
        end

        # A closed set's rows — a one-field set is its values; a set
        # whose rows carry more (StatementFrequency's cadence plus a
        # retention and a fee) leads with the first field and keeps the
        # rest beside it, so no row loses what makes it distinct.
        #
        # @param members [Array<Hash{Symbol => Object}>] the closed set's member rows
        # @return [String] "One of: …" (multi-field rows) or "One of …" (single-field)
        def closed_set_sentence(members)
          if members.first && members.first.size > 1
            rows = members.map do |row|
              lead, *rest = row.map { |field, value| [field, value] }
              "#{lead.last} (#{rest.map { |field, value| "#{Naming.words(field).downcase} #{value}" }.join(', ')})"
            end
            "One of: #{rows.join('; ')}."
          else
            "One of #{Naming.to_sentence_list(members.flat_map(&:values).uniq.map(&:to_s), conj: 'or')}."
          end
        end

        # "Always true: an amount is positive; a currency is a three-letter
        # code." — the rules as their author wrote them, kept out of the
        # definition sentence (a rule hidden inside a definition is a rule
        # a reader misses).
        #
        # @param rules [Array<String>] rendered invariant sentences
        # @return [String, nil] "Always true: …" joining every rule, or nil if
        #   `rules` is empty
        def rules_line(rules)
          return nil if rules.empty?

          clauses = rules.map { |rule| lower_first(rule.sub(/\.\z/, "")) }
          "Always true: #{clauses.join('; ')}."
        end

        # Describes a command's goal and who does it.
        #
        # @param command [Bluebook::Command] the command to describe
        # @return [String, nil] the command's goal and/or its role sentence, or nil
        #   if it declares neither
        def command_sentence(command)
          parts = []
          parts << with_period(command.goal) if command.goal
          parts << "Done by the #{Naming.words(command.role).downcase}." if command.role
          parts.empty? ? nil : parts.join(" ")
        end

        # Describes when an event is recorded and what it prompts.
        #
        # @param facts [Hash{Symbol => Object}] an `:event`-kind entry's facts:
        #   `:raised_by` (`Array<Array(Bluebook::Aggregate, Bluebook::Command)>`) and
        #   `:policies` (`Array<Bluebook::Policy>`)
        # @param index [Glossary::Index] the document's link index
        # @return [String] which commands record the event, and, when any policy
        #   reacts to it, which ones it prompts
        def event_sentence(facts, index)
          raisers = command_links(facts[:raised_by], index)
          sentence = "Recorded after #{Naming.to_sentence_list(raisers, conj: 'or')}."
          reactions = facts[:policies].map { |policy| index.link(:policy, policy.name) }
          sentence += " Prompts #{Naming.to_sentence_list(reactions)}." unless reactions.empty?
          sentence
        end

        # "When Customer suspended happens, Account is asked to Freeze
        # account, once for each row of Open for customer." — a
        # cross-domain trigger (`across "Compliance"`) is spoken as words
        # with the domain named, since nothing here to link to exists.
        #
        # @param policy [Bluebook::Policy] the policy to describe
        # @param index [Glossary::Index] the document's link index
        # @return [String] when the policy fires and what it asks for
        def policy_sentence(policy, index)
          holder, command = split_trigger(policy.trigger_command)
          asked = if policy.target_domain
                    "#{Naming.words(holder)} is asked to #{Naming.words(command).downcase}, " \
                      "in #{Naming.words(policy.target_domain)}"
                  else
                    "#{index.link(:aggregate, holder)} is asked to #{index.link(:command, command, within: holder)}"
                  end
          sentence = "When #{index.link(:event, bare(policy.on_event))} happens, #{asked}"
          if policy.for_each
            query_holder, query = split_trigger(policy.for_each)
            sentence += ", once for each row of #{index.link(:query, query, within: query_holder)}"
          end
          "#{sentence}."
        end

        # Describes when a saga begins and ends, and its states along the way.
        #
        # @param shape [Hash{Symbol => Object}] a process manager's `to_h`, read for
        #   `:starts_on`, `:ends_on`, and `:states`
        # @param index [Glossary::Index] the document's link index
        # @return [String] when the saga begins and ends, and, when it declares any,
        #   the states it can be in along the way
        def saga_sentence(shape, index)
          sentence = "Begins when #{index.link(:event, bare(shape[:starts_on]))} happens " \
                     "and ends when #{index.link(:event, bare(shape[:ends_on]))} happens."
          states = Array(shape[:states]).map { |state| spoken(state) }
          sentence += " Along the way it can be #{Naming.to_sentence_list(states, conj: 'or')}." unless states.empty?
          sentence
        end

        # A noun list, deliberately — "Responsible for Credit and Debit",
        # never "Can credit and debit": banking's System role raises
        # `Debited` and `Credited`, and "can … debited" is a wrong
        # sentence. The headwords are already what people say.
        #
        # @param issues [Array<Array(Bluebook::Aggregate, Bluebook::Command)>] the
        #   role's own `[holder, command]` pairs
        # @param index [Glossary::Index] the document's link index
        # @return [String] "Responsible for …", naming every command
        def role_sentence(issues, index)
          "Responsible for #{Naming.to_sentence_list(command_links(issues, index))}."
        end

        # The same word for two different things gets its holder beside it
        # — a role responsible for CardPayment's Reverse and Transfer's
        # Reverse is responsible for "Reverse (card payment)" and
        # "Reverse (transfer)", not for "Reverse" twice.
        #
        # @param issues [Array<Array(Bluebook::Aggregate, Bluebook::Command)>] each
        #   `[holder, command]` pair to link
        # @param index [Glossary::Index] the document's link index
        # @return [Array<String>] one Markdown link per distinct `[holder, command]`
        #   pair, qualified with the holder's name when the command name repeats
        def command_links(issues, index)
          issues = issues.uniq { |holder, command| [holder.hecks_name, command.hecks_name] }
          repeated = issues.map { |_holder, command| command.hecks_name }.tally.select { |_name, count| count > 1 }
          issues.map do |holder, command|
            label = if repeated.key?(command.hecks_name)
                      "#{Naming.words(command.hecks_name)} (#{Naming.words(holder.hecks_name).downcase})"
                    end
            index.link(:command, command.hecks_name, within: holder.hecks_name, label: label)
          end
        end

        # ── small carpentry ─────────────────────────────────────────────

        # Splits a dotted `Holder.command` trigger into its two parts.
        #
        # @param dotted [String, Symbol] a `"Holder.command"` reference
        # @return [Array(String, String)] `[holder, command]`
        def split_trigger(dotted)
          holder, _dot, command = dotted.to_s.rpartition(".")
          [holder, command]
        end

        # Strips a dotted name down to its last segment.
        #
        # @param qualified [String, Symbol] a dotted or bare name, such as
        #   `"Handler.Dispatch"` or `"Freeze"`
        # @return [String] the name after the last `.`, or the whole name if it has none
        def bare(qualified) = qualified.to_s.split(".").last

        # Ensures text ends in sentence-ending punctuation.
        #
        # @param text [String, Symbol, nil] the text to punctuate
        # @return [String] `text`, stripped, with a trailing `.` added if it has no
        #   sentence-ending punctuation already
        def with_period(text) = text.to_s.strip.end_with?(".", "!", "?") ? text.to_s.strip : "#{text.to_s.strip}."

        # Lowercases a leading capital letter.
        #
        # @param text [String] the text to adjust
        # @return [String] `text` with a leading uppercase letter lowercased
        def lower_first(text) = text.sub(/\A[[:upper:]]/, &:downcase)

        # Uppercases a leading lowercase letter.
        #
        # @param text [String] the text to adjust
        # @return [String] `text` with a leading lowercase letter uppercased
        def upper_first(text) = text.sub(/\A[[:lower:]]/, &:upcase)
      end
    end
  end
end
