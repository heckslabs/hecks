module Hecks
  module Forms
    # The `<select>` options for every `:reference` field in a Field tree, keyed by path.
    # Shared by the command and query form renderers.
    module ReferenceOptions
      # Returns `{path => [[id, id], ...]}`; nil for a field whose options cannot be read.
      def self.collect(registry, domain, fields)
        targets = {}
        walk(fields) { |field| targets[field.path] = field.target_aggregate if field.kind == :reference }
        targets.transform_values { |aggregate| aggregate && options_for(registry, domain, aggregate) }
      end

      def self.walk(fields, &block)
        fields.each do |field|
          block.call(field)
          walk(field.children, &block) if field.children
        end
      end

      def self.options_for(registry, domain, aggregate)
        registry.repository(domain, aggregate).all.first(200).map { |instance| [instance.id, instance.id] }
      rescue StandardError
        nil # a wiring gap (no repository bound) degrades to a plain text id input, not a 500
      end
    end
  end
end
