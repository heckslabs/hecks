module Hecks
  module Runtime
    # Copies `projects` field values from their referenced records into the owning
    # aggregate's records; called explicitly, never at dispatch time (ADR 0025).
    module RebuildSweep
      module_function

      # Refreshes one aggregate's projected fields across every record it holds.
      # Saves only records whose projected value differs from what is stored.
      #
      # @param registry [Runtime::Registry] the booted registry to read repositories from
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate whose `projected_fields` to
      #   refresh
      # @return [Integer] the number of records actually changed and saved
      def call(registry, domain, aggregate)
        return 0 if aggregate.projected_fields.empty?

        repository = registry.repository(domain, aggregate)
        repository.all.count { |record| refresh(registry, domain, aggregate, record, repository) }
      end

      # Refreshes one record's projected fields in place, saving it if any changed.
      #
      # @return [Boolean] true if `record` was saved
      def refresh(registry, domain, aggregate, record, repository)
        changed = false

        aggregate.projected_fields.each do |field|
          value = remote_value(registry, domain, aggregate, record, field)
          next if value.nil?
          next if record.key?(field.name) && record[field.name] == value

          record[field.name] = value
          changed = true
        end

        repository.save(record) if changed
        changed
      end

      # Reads the current value of a projected field's remote target field.
      # Nil when the reference does not resolve here, names no target, or finds no record.
      def remote_value(registry, domain, aggregate, record, field)
        target = aggregate.attribute(field.reference)&.type&.resolve
        return nil unless target

        id = record[field.reference]
        return nil if id.nil?

        remote = registry.repository(domain, target).find(id.to_s)
        unwrap_single_field(target, field, remote&.[](field.remote_field))
      end

      # A remote field typed by a single-field value object is copied as its one scalar, so the
      # projecting aggregate holds `123`, never `{ value: 123 }`. Any other value is copied as is.
      def unwrap_single_field(target, field, value)
        attribute = target.attribute(field.remote_field)
        sole = attribute && target.value_object(attribute.type)&.sole_attribute
        return value unless sole && !value.nil?

        value.is_a?(Hash) ? value.fetch(sole.name) { value[sole.name.to_s] } : value[sole.name]
      end
    end
  end
end
