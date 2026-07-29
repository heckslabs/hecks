require "securerandom"

module Hecksagain
  module Runtime
    class CommandInterpreter
      attr_reader :registry

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, command, args)
        args       = normalize_args(aggregate, command, args)
        repository = @registry.repository(domain, aggregate)
        instance   = hydrate(repository, aggregate, command, args)

        @rules.enforce_givens(instance, command, args)
        transition = @rules.admissible_transition(aggregate, command, instance)
        assign_creation_attributes(instance, aggregate, command, args) if command.creates?
        command.mutations.each { |mutation| apply(instance, aggregate, mutation, args) }
        instance[aggregate.lifecycle.field] = transition.target if transition

        repository.save(instance)

        [instance, @rules.emit(command, domain, aggregate, instance, args, repository)]
      end

      private

      def hydrate(repository, aggregate, command, args)
        if command.creates?
          id = identity_from(aggregate, args, aggregate.identified_by || :id) || mint_id(aggregate)
          Instance.new(aggregate: aggregate, id: id)
        else
          id = identity_from(aggregate, args, aggregate.identified_by || :id) ||
               identity_from(aggregate, args, reference_key(command)) ||
               raise(NotFound, "#{command.name} acts on an existing #{aggregate.name} — pass #{aggregate.identified_by}:")
          repository.find(id) || raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{id.inspect}")
        end
      end

      def reference_key(command)
        target = command.references.to_s
        return nil if target.empty?

        Naming.reference_key(target)
      end

      def normalize_args(aggregate, command, args)
        command.attributes.each_with_object(args.dup) do |attribute, normalized|
          next unless normalized.key?(attribute.name)

          normalized[attribute.name] = Value.for_attribute(aggregate, attribute, normalized[attribute.name])
        end
      end

      def identity_from(aggregate, args, key)
        return nil unless key && args.key?(key)

        attribute = aggregate.attribute(aggregate.identified_by || :id)
        raw       = args[key]
        Value.identifier(attribute ? Value.for_attribute(aggregate, attribute, raw) : raw)
      end

      def mint_id(aggregate)
        "#{aggregate.storage_name}-#{SecureRandom.hex(4)}"
      end

      def assign_creation_attributes(instance, aggregate, command, args)
        command.attributes.each do |attr|
          next unless aggregate.attribute(attr.name)
          next unless args.key?(attr.name)

          instance[attr.name] = Value.for(aggregate, attr.name, args[attr.name])
        end
      end

      def apply(instance, aggregate, mutation, args)
        case mutation.op
        when :set
          value = @rules.resolve_source(mutation.source, args)
          instance[mutation.target] = Value.for(aggregate, mutation.target, value)
        when :append
          instance[mutation.target] = appended(instance, aggregate, mutation, args)
        when :increment, :decrement
          amount = @rules.resolve_source(mutation.source, args)
          attribute = aggregate.attribute(mutation.target)
          amount = Value.for_attribute(aggregate, attribute, amount) if attribute
          instance[mutation.target] = @rules.arithmetic(
            instance[mutation.target],
            amount,
            mutation.target,
            @rules.sign_of(mutation.op)
          )
        end
      end

      def appended(instance, aggregate, mutation, args)
        fields       = mutation.source.transform_values { |source| source.is_a?(Symbol) ? args[source] : source }
        element_type = aggregate.attribute(mutation.target)&.type
        value_object = aggregate.value_object(element_type)
        if value_object
          value_object.attributes.each do |attribute|
            fields[attribute.name] = Value.scalar(fields[attribute.name]) if fields[attribute.name].is_a?(Value)
          end
        end
        element      = value_object ? Value.build(value_object, fields) : entity_element(aggregate, element_type, instance[mutation.target], fields)

        Array(instance[mutation.target]) + [element]
      end

      def entity_element(aggregate, element_type, current, fields)
        entity = aggregate.entities.find { |e| e.name == element_type.to_s }
        return fields unless entity

        entity.attributes.each do |attribute|
          next unless fields.key?(attribute.name)

          fields[attribute.name] = Value.for_attribute(aggregate, attribute, fields[attribute.name])
        end
        if entity.identified_by && !fields.key?(entity.identified_by)
          attribute = entity.attribute(entity.identified_by)
          fields[entity.identified_by] = Value.from_identifier(aggregate, attribute, Array(current).size + 1)
        end
        fields[entity.lifecycle.field] ||= entity.lifecycle.default if entity.lifecycle
        fields
      end
    end
  end
end
