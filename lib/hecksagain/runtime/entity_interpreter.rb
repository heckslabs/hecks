
module Hecksagain
  module Runtime
    class EntityInterpreter
      attr_reader :registry

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, dotted, args)
        entity_name, command_name = Naming.split_dotted(dotted)
        entity  = aggregate.entities.find { |e| e.name == entity_name } ||
                  raise(UnknownVerb, "#{aggregate.name} has no entity #{entity_name.inspect}")
        command = entity.command(command_name) ||
                  raise(UnknownVerb, "#{entity_name} has no command #{command_name.inspect}")

        args       = normalize_args(aggregate, command, args)
        repository = @registry.repository(domain, aggregate)
        instance   = parent(repository, aggregate, entity_name, command_name, args)
        element    = element_of(aggregate, entity, entity_name, command_name, instance, args)

        view = Instance.new(aggregate: entity, id: element[entity.identified_by].to_s, state: element)
        @rules.enforce_givens(view, command, args)
        transition = @rules.admissible_transition(entity, command, view)
        command.mutations.each { |mutation| apply_to_element(aggregate, entity, element, mutation, args) }
        element[entity.lifecycle.field] = transition.target if transition

        repository.save(instance)

        [instance, @rules.emit(command, domain, aggregate, instance, args, repository)]
      end

      private

      def parent(repository, aggregate, entity_name, command_name, args)
        parent_key = aggregate.identified_by || :id
        parent_id = args[parent_key] || args[:id] ||
                    raise(NotFound, "#{command_name} acts on a #{aggregate.name}'s #{entity_name} — pass #{aggregate.identified_by}:")
        parent_id = Value.identifier(Value.for_attribute(aggregate, aggregate.attribute(parent_key), parent_id))
        repository.find(parent_id) ||
          raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{parent_id.inspect}")
      end

      def element_of(aggregate, entity, entity_name, command_name, instance, args)
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, "#{aggregate.name} holds no list of #{entity_name}")
        key  = entity.identified_by
        want = args[key] ||
               raise(NotFound, "#{command_name} acts on one #{entity_name} — pass #{key}:")
        want = Value.for_attribute(aggregate, entity.attribute(key), want)

        Array(instance[list_attr.name]).find { |el| el[key] == want } ||
          raise(NotFound, "no #{entity_name} with #{key} #{Value.materialize(want).to_json} on #{aggregate.name} #{instance.id.inspect}")
      end

      def apply_to_element(aggregate, entity, element, mutation, args)
        case mutation.op
        when :set
          value = @rules.resolve_source(mutation.source, args)
          attribute = entity.attribute(mutation.target)
          element[mutation.target] = attribute ? Value.for_attribute(aggregate, attribute, value) : value
        when :increment, :decrement
          attribute = entity.attribute(mutation.target)
          amount    = @rules.resolve_source(mutation.source, args)
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute
          element[mutation.target] = @rules.arithmetic(
            element[mutation.target],
            amount,
            mutation.target,
            @rules.sign_of(mutation.op)
          )
        end
      end

      def normalize_args(aggregate, command, args)
        command.attributes.each_with_object(args.dup) do |attribute, normalized|
          next unless normalized.key?(attribute.name)

          normalized[attribute.name] = Value.for_attribute(aggregate, attribute, normalized[attribute.name])
        end
      end
    end
  end
end
