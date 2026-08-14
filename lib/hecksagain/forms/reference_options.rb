module Hecksagain
  module Forms
    # A Field tree (field_shape.rb) -> `{path => [[id, label], ...]}` for
    # every `:reference` field in it — the options a `<select>` needs.
    # Shared by CommandFormRenderer and QueryFormRenderer alike: a
    # command's own reference field and a query's own reference parameter
    # resolve against the same repository the same way, and neither word
    # owns this more than the other.
    module ReferenceOptions
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
