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
          id = args[aggregate.identified_by] || mint_id(aggregate)
          Instance.new(aggregate: aggregate, id: id)
        else
          id = args[aggregate.identified_by] || args[:id] || args[reference_key(command)] ||
               raise(NotFound, "#{command.name} acts on an existing #{aggregate.name} — pass #{aggregate.identified_by}:")
          repository.find(id) || raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{id.inspect}")
        end
      end

      def reference_key(command)
        target = command.references.to_s
        return nil if target.empty?

        Naming.reference_key(target)
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
          instance[mutation.target] = @rules.arithmetic(
            instance[mutation.target],
            @rules.resolve_source(mutation.source, args),
            mutation.target,
            @rules.sign_of(mutation.op)
          )
        end
      end

      def appended(instance, aggregate, mutation, args)
        fields       = mutation.source.transform_values { |source| source.is_a?(Symbol) ? args[source] : source }
        element_type = aggregate.attribute(mutation.target)&.type
        value_object = aggregate.value_object(element_type)
        element      = value_object ? Value.build(value_object, fields) : entity_element(aggregate, element_type, instance[mutation.target], fields)

        Array(instance[mutation.target]) + [element]
      end

      def entity_element(aggregate, element_type, current, fields)
        entity = aggregate.entities.find { |e| e.name == element_type.to_s }
        return fields unless entity

        fields[entity.identified_by] ||= Array(current).size + 1 if entity.identified_by
        fields[entity.lifecycle.field] ||= entity.lifecycle.default if entity.lifecycle
        fields
      end
    end
  end
end
