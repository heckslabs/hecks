
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

        repository = @registry.repository(domain, aggregate)
        instance   = parent(repository, aggregate, entity_name, command_name, args)
        element    = element_of(aggregate, entity, entity_name, command_name, instance, args)

        view = Instance.new(aggregate: entity, id: element[entity.identified_by].to_s, state: element)
        @rules.enforce_givens(view, command, args)
        transition = @rules.admissible_transition(entity, command, view)
        command.mutations.each { |mutation| apply_to_element(element, mutation, args) }
        element[entity.lifecycle.field] = transition.target if transition

        repository.save(instance)

        [instance, @rules.emit(command, domain, aggregate, instance, args, repository)]
      end

      private

      def parent(repository, aggregate, entity_name, command_name, args)
        parent_id = args[aggregate.identified_by] || args[:id] ||
                    raise(NotFound, "#{command_name} acts on a #{aggregate.name}'s #{entity_name} — pass #{aggregate.identified_by}:")
        repository.find(parent_id) ||
          raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{parent_id.inspect}")
      end

      def element_of(aggregate, entity, entity_name, command_name, instance, args)
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, "#{aggregate.name} holds no list of #{entity_name}")
        key  = entity.identified_by
        want = args[key] ||
               raise(NotFound, "#{command_name} acts on one #{entity_name} — pass #{key}:")

        Array(instance[list_attr.name]).find { |el| el[key] == want } ||
          raise(NotFound, "no #{entity_name} with #{key} #{want.inspect} on #{aggregate.name} #{instance.id.inspect}")
      end

      def apply_to_element(element, mutation, args)
        case mutation.op
        when :set
          element[mutation.target] = @rules.resolve_source(mutation.source, args)
        when :increment, :decrement
          element[mutation.target] = @rules.arithmetic(
            element[mutation.target],
            @rules.resolve_source(mutation.source, args),
            mutation.target,
            @rules.sign_of(mutation.op)
          )
        end
      end
    end
  end
end
