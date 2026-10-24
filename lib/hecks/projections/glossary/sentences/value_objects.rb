require_relative "../../../naming"
require_relative "../../statements"
require_relative "../sensitivity"
require_relative "../../../bluebook/named_pattern"

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

          # What each named pattern asks of a value, in words.
          PATTERN_WORDS = {
            present: "must not be blank", not_empty: "must not be empty", no_whitespace: "must have no spaces",
            snake_name: "must be lowercase words joined by underscores", git_sha: "must be a commit id",
            digits: "must be digits only"
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

            return bare_sentence(attributes.first, index, within) if bare_value?(attributes)

            fields = attributes.map { |field| field_phrase(field, index, within, sensitive[field.name.to_s]) }
            "Made up of #{Naming.to_sentence_list(fields)}."
          end

          def bare_value?(attributes) = attributes.size == 1 && attributes.first.name.to_s == "value"

          # "Text that must not be blank.", or just "A whole number." when nothing constrains it.
          def bare_sentence(field, index, within)
            rule = constraint(field)
            "#{Sentences.upper_first(type_words(field, index, within))}#{" that #{rule}" if rule}."
          end

          # "amount (a whole number)", "name (text, must not be blank)", or, when marked
          # sensitive, "medications (text, PHI)".
          def field_phrase(field, index, within, marking = nil)
            detail = [type_words(field, index, within), constraint(field), ("optional" if field.optional?),
                      (Sensitivity.tag(marking) if marking)].compact.join(", ")
            "#{Naming.words(field.name).downcase} (#{detail})"
          end

          # A plain type in words, a reference as a link to what it points at, otherwise a link
          # to the value's own term.
          def type_words(field, index, within)
            inner = if field.reference? then index.link(:aggregate, field.target_name)
                    else TYPE_WORDS[field.type.to_s] || index.link(:value_object, field.type.to_s, within: within)
                    end
            field.list? ? "a list of #{inner}" : inner
          end

          # What a field's pattern asks of its value, or nil when it has none.
          def constraint(field)
            return nil unless field.pattern

            name = Bluebook::NamedPattern::TABLE.key(field.pattern)
            name ? PATTERN_WORDS[name] : "must follow a set format"
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

            clauses = rules.map { |rule| Sentences.lower_first(rule.delete_suffix(".")) }
            "Always true: #{clauses.join("; ")}."
          end
        end
      end
    end
  end
end
