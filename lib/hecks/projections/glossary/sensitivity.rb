require_relative "../../naming"

module Hecks
  module Projections
    module Glossary
      # The sensitive fields a glossary flags, read from markings handed in as
      # `options[:markings]` and keyed by aggregate name and dotted field path.
      module Sensitivity
        module_function

        def for_aggregate(markings, chapter_name, aggregate)
          qualified = "#{chapter_name}::#{aggregate.hecks_name}"
          markings.select { |marking| marking[:domain].to_s == qualified }
        end

        # Marked fields inside a value object, matched by attribute name then field.
        def for_value_object(marked, aggregate, value_object)
          holders = aggregate.attributes.select { |attribute| attribute.type.to_s == value_object.hecks_name }
          holder_names = holders.map { |attribute| attribute.name.to_s }
          marked.each_with_object({}) do |marking, tagged|
            head, field, *deeper = marking[:attribute_path].to_s.split(".")
            tagged[field] = marking if field && deeper.empty? && holder_names.include?(head)
          end
        end

        # Uppercased, never otherwise reworded — the category vocabulary is the deployment's own.
        def tag(marking) = marking[:category].to_s.upcase

        # Renders one "Handled as sensitive" line: field, category, and who may read it unredacted.
        def sentence(marking)
          path = marking[:attribute_path].to_s.split(".").map { |part| Naming.words(part).downcase }.join(" ")
          reader = Naming.words(marking[:readable_by]).downcase
          "#{path.sub(/\A[[:lower:]]/, &:upcase)}: #{tag(marking)}, read unredacted only by the #{reader}."
        end
      end
    end
  end
end
