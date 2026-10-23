require_relative "../../plain_english"
require_relative "paths"

module Hecks
  module Projections
    module Glossary
      module Sentences
        # The sentence a list's term carries, read from its filters, ordering and limit:
        # "Orders that are available, sorted by pizza name, A to Z."
        module Queries
          # How each comparison is said between a field and its value.
          OPERATORS = {
            "eq" => "is", "ne" => "is not", "lt" => "is less than", "lte" => "is at most",
            "gt" => "is more than", "gte" => "is at least", "in" => "is", "contains" => "includes"
          }.freeze

          module_function

          # @param query [Bluebook::Query] the query
          # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct it lists
          # @param value_objects [Array<Bluebook::ValueObject>] the aggregate's value objects
          # @return [Array<String>] the author's description, when there is one, then the
          #   derived sentence
          def paragraphs(query, holder, value_objects)
            paths = Paths.new(holder, value_objects)
            [query.description, sentence(query, holder, paths), limit(query)].compact
          end

          def sentence(query, holder, paths)
            things = PlainEnglish.plural(PlainEnglish.noun(holder.hecks_name))
            filters = query.wheres.map { |clause| filter(clause, paths) }
            subject = filters.empty? ? "All #{things}" : "#{PlainEnglish.upper(things)} #{filters.join(" and ")}"
            "#{subject}#{order(query, things, paths)}."
          end

          # "that are available" on the lifecycle field, otherwise "whose price is less than ...".
          def filter(clause, paths)
            operator = clause.op.to_s
            value = value_words(clause.value, operator)
            return "that are #{"not " if operator == "ne"}#{value}" if paths.lifecycle?(clause.field)
            return "that have none #{value}" if operator == "none_in_state"

            "whose #{paths.label(clause.field)} #{OPERATORS.fetch(operator, operator.tr("_", " "))} #{value}"
          end

          # A parameter is "the ceiling you give"; a list of states is "open or frozen".
          def value_words(value, operator)
            return "the #{PlainEnglish.noun(value)} you give" if value.is_a?(Symbol)
            return PlainEnglish.states(value.to_s.split(",").map(&:strip)) if operator == "in"

            PlainEnglish.state(value)
          end

          # ", sorted by price, lowest first", and where unset values go when that is declared.
          def order(query, things, paths)
            order_by = query.order_by
            return "" unless order_by

            label = paths.label(order_by.field)
            words = direction(paths.type(order_by.field), order_by.direction.to_s == "desc")
            ", sorted by #{label}#{words}#{nulls(query, things, label)}"
          end

          def direction(type, descending)
            case type
            when "String" then descending ? ", Z to A" : ", A to Z"
            when "Integer", "Float" then descending ? ", highest first" : ", lowest first"
            else descending ? ", in reverse order" : ""
            end
          end

          def nulls(query, things, label)
            mode = query.null_semantics&.mode.to_s
            return "" unless %w[first last].include?(mode)

            ", with #{things} that have no #{label} #{mode}"
          end

          # "Shows at most 50." when the list is capped.
          def limit(query)
            value = query.limit&.value
            return nil unless value

            value.is_a?(Symbol) ? "Shows at most the number you give." : "Shows at most #{value}."
          end
        end
      end
    end
  end
end
