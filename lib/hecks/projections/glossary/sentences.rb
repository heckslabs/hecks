require_relative "../../naming"
require_relative "../statements"
require_relative "sensitivity"
require_relative "sentences/value_objects"

module Hecks
  module Projections
    module Glossary
      # Every sentence the glossary says. Authored text is verbatim; derived text is built
      # mechanically from one declared fact, and a fact with no plain phrasing gets none.
      # Links come only from declared structure, never from searching prose.
      module Sentences
        # The one sentence each kind of term other than an entity or value object carries.
        SINGLES = {
          command:    ->(facts, _index) { command_sentence(facts[:command]) },
          query:      ->(facts, _index) { facts[:query].description },
          event:      ->(facts, index) { event_sentence(facts, index) },
          policy:     ->(facts, index) { policy_sentence(facts[:policy], index) },
          saga:       ->(facts, index) { saga_sentence(facts[:saga], index) },
          role:       ->(facts, index) { role_sentence(facts[:commands], index) },
          read_model: ->(facts, _index) { facts[:read_model].description }
        }.freeze

        module_function

        def paragraphs(entry, index)
          facts = entry.facts
          case entry.kind
          when :entity       then holder_paragraphs(facts[:entity])
          when :value_object then value_object_paragraphs(entry, index)
          else [SINGLES.fetch(entry.kind).call(facts, index)]
          end.compact
        end

        def value_object_paragraphs(entry, index)
          facts = entry.facts
          ValueObjects.paragraphs(facts[:value_object], index, entry.within, facts.fetch(:sensitive, {}))
        end

        def holder_paragraphs(holder)
          [holder.description, holder.lifecycle && lifecycle_sentence(holder.lifecycle)].compact
        end

        def lifecycle_sentence(lifecycle)
          states = ([lifecycle.default] + lifecycle.transitions.map { |_name, transition| transition.target }).uniq
          "Starts out #{spoken(lifecycle.default)}. " \
            "Can be #{Naming.to_sentence_list(states.map { |state| spoken(state) }, conj: "or")}."
        end

        def spoken(state) = state.to_s.tr("_", " ")

        def command_sentence(command)
          parts = []
          parts << with_period(command.goal) if command.goal
          parts << "Done by the #{Naming.words(command.role).downcase}." if command.role
          parts.empty? ? nil : parts.join(" ")
        end

        def event_sentence(facts, index)
          raisers = command_links(facts[:raised_by], index)
          sentence = "Recorded after #{Naming.to_sentence_list(raisers, conj: "or")}."
          reactions = facts[:policies].map { |policy| index.link(:policy, policy.name) }
          sentence += " Prompts #{Naming.to_sentence_list(reactions)}." unless reactions.empty?
          sentence
        end

        # A cross-domain trigger (`across "Compliance"`) is spoken as words with the
        # domain named, since there is nothing here to link to.
        def policy_sentence(policy, index)
          sentence = "When #{index.link(:event, bare(policy.on_event))} happens, #{asked_phrase(policy, index)}"
          if policy.for_each
            query_holder, query = split_trigger(policy.for_each)
            sentence += ", once for each row of #{index.link(:query, query, within: query_holder)}"
          end
          "#{sentence}."
        end

        # What the policy asks of whom, linked unless the trigger crosses into another domain.
        def asked_phrase(policy, index)
          holder, command = split_trigger(policy.trigger_command)
          if policy.target_domain
            "#{Naming.words(holder)} is asked to #{Naming.words(command).downcase}, " \
              "in #{Naming.words(policy.target_domain)}"
          else
            "#{index.link(:aggregate, holder)} is asked to #{index.link(:command, command, within: holder)}"
          end
        end

        def saga_sentence(shape, index)
          sentence = "Begins when #{index.link(:event, bare(shape[:starts_on]))} happens " \
                     "and ends when #{index.link(:event, bare(shape[:ends_on]))} happens."
          states = Array(shape[:states]).map { |state| spoken(state) }
          sentence += " Along the way it can be #{Naming.to_sentence_list(states, conj: "or")}." unless states.empty?
          sentence
        end

        # A noun list, not "Can credit and debit": a role that raises `Debited` would
        # read "can … debited", which is wrong.
        def role_sentence(issues, index)
          "Responsible for #{Naming.to_sentence_list(command_links(issues, index))}."
        end

        # A command name shared by two holders gets its holder beside it:
        # "Reverse (card payment)" and "Reverse (transfer)", not "Reverse" twice.
        def command_links(issues, index)
          issues = issues.uniq { |holder, command| [holder.hecks_name, command.hecks_name] }
          repeated = issues.map { |_holder, command| command.hecks_name }.tally.select { |_name, count| count > 1 }
          issues.map { |holder, command| command_link(holder, command, index, repeated.key?(command.hecks_name)) }
        end

        def command_link(holder, command, index, shared)
          label = holder_label(holder, command) if shared
          index.link(:command, command.hecks_name, within: holder.hecks_name, label: label)
        end

        def holder_label(holder, command)
          "#{Naming.words(command.hecks_name)} (#{Naming.words(holder.hecks_name).downcase})"
        end

        def split_trigger(dotted)
          holder, _dot, command = dotted.to_s.rpartition(".")
          [holder, command]
        end

        def bare(qualified) = qualified.to_s.split(".").last

        def with_period(text) = text.to_s.strip.end_with?(".", "!", "?") ? text.to_s.strip : "#{text.to_s.strip}."

        def lower_first(text) = text.sub(/\A[[:upper:]]/, &:downcase)

        def upper_first(text) = text.sub(/\A[[:lower:]]/, &:upcase)
      end
    end
  end
end
