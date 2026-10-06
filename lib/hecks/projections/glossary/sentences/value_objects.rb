require_relative "../../../naming"
require_relative "../../statements"
require_relative "../sensitivity"

module Hecks
  module Projections
    module Glossary
      module Sentences
        # The sentences a value object's term carries: what it is made of, or the closed set it
        # names, and the rules that always hold for it.
        module ValueObjects
          TYPE_WORDS = {
            "Integer" => "a whole number", "Float" => "a number", "String" => "text",
            "Boolean" => "yes or no", "TrueClass" => "yes or no", "FalseClass" => "yes or no"
          }.freeze

          module_function

          def paragraphs(value_object, index, within, sensitive = {})
            rules = value_object.invariants.map { |invariant| Statements.invariant_statement(invariant) }
            [sentence(value_object, index, within, sensitive), rules_line(rules)].compact
          end

          # A one-field object whose field is just "value" reads as its type ("Text.").
          def sentence(value_object, index, within, sensitive = {})
            return closed_set_sentence(value_object.members) if value_object.closed_set?

            attributes = value_object.attributes
            return "A marker with no details of its own." if attributes.empty?

            return "#{Sentences.upper_first(type_words(attributes.first, index, within))}." if bare_value?(attributes)

            fields = attributes.map { |field| field_phrase(field, index, within, sensitive[field.name.to_s]) }
            "Made up of #{Naming.to_sentence_list(fields)}."
          end

          def bare_value?(attributes) = attributes.size == 1 && attributes.first.name.to_s == "value"

          # "amount (a whole number)", or "medications (text, PHI)" when marked sensitive.
          def field_phrase(field, index, within, marking = nil)
            detail = [type_words(field, index, within), (Sensitivity.tag(marking) if marking)].compact.join(", ")
            "#{Naming.words(field.name).downcase} (#{detail})"
          end

          def type_words(field, index, within)
            type  = field.type.to_s
            inner = TYPE_WORDS[type] || index.link(:value_object, type, within: within)
            field.list? ? "a list of #{inner}" : inner
          end

          # A multi-field row leads with its first field and keeps the rest beside it,
          # so no row loses what makes it distinct.
          def closed_set_sentence(members)
            if members.first && members.first.size > 1
              "One of: #{members.map { |row| row_phrase(row) }.join("; ")}."
            else
              "One of #{Naming.to_sentence_list(members.flat_map(&:values).uniq.map(&:to_s), conj: "or")}."
            end
          end

          def row_phrase(row)
            lead, *rest = row.map { |field, value| [field, value] }
            "#{lead.last} (#{rest.map { |field, value| "#{Naming.words(field).downcase} #{value}" }.join(", ")})"
          end

          # Kept apart from the definition sentence, where a reader would miss a rule.
          def rules_line(rules)
            return nil if rules.empty?

            clauses = rules.map { |rule| Sentences.lower_first(rule.sub(/\.\z/, "")) }
            "Always true: #{clauses.join("; ")}."
          end
        end
      end
    end
  end
end
