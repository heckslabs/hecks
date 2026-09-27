module Hecks
  module Bluebook
    class Assembly
      # Projects `contracts.rb`'s `fields:` table from the language's own grammar,
      # for fields simple enough to derive: scalar, non-reference, non-walked.
      module Specializer
        module_function

        # Finds a construct by name — an aggregate, or an entity nested anywhere
        # under one (recursively, since an entity like Dispatch nests two deep).
        def construct_for(chapter, name)
          chapter.aggregate(name) || chapter.aggregates.filter_map { |a| find_entity(a, name) }.first
        end

        # Searches a construct's own entities, recursively, for one by name.
        def find_entity(construct, name)
          construct.entities.each do |candidate|
            return candidate if candidate.hecks_name == name

            found = find_entity(candidate, name)
            return found if found
          end
          nil
        end

        # Builds `category`'s own `fields:` entries from the language's scalar,
        # non-reference attributes, skipping any the contract already derives.
        def fields_for(category)
          language = construct_for(MetaValidator.grammar_registry.bluebook("Bluebook"), category.to_s)
          walked   = Assembly.contract(category).walked
          language.attributes.each_with_object({}) do |attribute, fields|
            next if attribute.list? || attribute.reference?
            next if walked.include?(attribute.name)

            fields[attribute.name] = [attribute.name, :plain]
          end
        end
      end
    end
  end
end
