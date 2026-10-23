require_relative "../../plain_english"
require_relative "../../statements"

module Hecks
  module Projections
    module Glossary
      module Sentences
        # The paragraphs an action's term carries: what it is for and who does it, what it needs,
        # what it checks first, what it changes, what it guarantees after, and what it records.
        module Actions
          # How each kind of change is said, before the field it changes.
          CHANGES = {
            "set" => "sets", "append" => "adds to", "increment" => "raises", "decrement" => "lowers",
            "multiply" => "scales", "clamp" => "limits", "remove" => "removes from",
            "delegate" => "passes on to", "corrects" => "corrects"
          }.freeze

          module_function

          # @param facts [Hash] the entry's facts: `:command`, `:holder` and `:value_objects`
          # @param index [Glossary::Index] resolves links to other terms
          # @return [Array<String>] the paragraphs, each present only when it has something to say
          def paragraphs(facts, index)
            command, holder = facts.values_at(:command, :holder)
            [Sentences.command_sentence(command), needs(command, index, facts[:within]),
             checks(holder, command), changes(holder, command), afterwards(command),
             records(command, index)].compact
          end

          # "Needs a topping (Topping name) and an amount (Topping amount)."
          def needs(command, index, within)
            fields = command.attributes.map { |field| need_phrase(field, index, within) }
            fields.empty? ? nil : "Needs #{Naming.to_sentence_list(fields)}."
          end

          def need_phrase(field, index, within)
            name = PlainEnglish.noun(field.name)
            name = PlainEnglish.a(name) unless field.list?
            detail = [ValueObjects.type_words(field, index, within), ("optional" if field.optional?)].compact
            "#{name} (#{detail.join(", ")})"
          end

          # "Allowed only when: the order is available; at most 10 toppings."
          def checks(holder, command)
            rules = Statements::Actions.checks(holder, command, said_by_move: false)
            rules.empty? ? nil : "Allowed only when: #{rules.join("; ")}."
          end

          # "Sets the customer name and moves the order from available to sold."
          def changes(holder, command)
            parts = command.mutations.group_by { |mutation| CHANGES.fetch(mutation.op.to_s, "changes") }
                           .map { |verb, mutations| change_phrase(verb, mutations) }
            parts << move(holder, command)
            parts.compact!
            parts.empty? ? nil : "#{PlainEnglish.upper(Naming.to_sentence_list(parts))}."
          end

          # "sets the name and the pizza"
          def change_phrase(verb, mutations)
            fields = mutations.map { |mutation| "the #{PlainEnglish.noun(mutation.target.to_s.split(".").last)}" }
            "#{verb} #{Naming.to_sentence_list(fields.uniq)}"
          end

          # The lifecycle move a command makes, as "moves the order from available to sold".
          def move(holder, command)
            lifecycle = holder.respond_to?(:lifecycle) && holder.lifecycle
            return nil unless lifecycle

            found = Statements::Actions.moves(lifecycle).find { |name, _move| name == command.hecks_name }
            found && Statements::Actions.move_phrase(found.last, "the #{PlainEnglish.noun(holder.hecks_name)}")
          end

          # "Afterwards, always: the balance fell by exactly the amount."
          def afterwards(command)
            rules = command.ensures.map { |rule| Statements::Actions.text(rule) }
            rules.empty? ? nil : "Afterwards, always: #{rules.join("; ")}."
          end

          # "Records Topping added."
          def records(command, index)
            events = command.emits.map { |event| index.link(:event, event.to_s.split(/::|\./).last) }
            events.empty? ? nil : "Records #{Naming.to_sentence_list(events)}."
          end
        end
      end
    end
  end
end
