
module Hecksagain
  module Runtime
    class EntityInterpreter
      attr_reader :registry

      # Set by a spec to observe dispatch order (Vocabulary::EntityDispatchOrder
      # in language/bluebook.bluebook) ; nil in production, always — see
      # CommandInterpreter.trace, the same mechanism.
      class << self
        attr_accessor :trace
      end

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, dotted, args)
        entity_name, command_name = Naming.split_dotted(dotted)
        entity  = aggregate.entities.find { |piece| piece.hecks_name == entity_name } ||
                  raise(UnknownVerb, "#{aggregate.hecks_name} has no entity #{entity_name.inspect}")
        command = entity.command(command_name) ||
                  raise(UnknownVerb, "#{entity_name} has no command #{command_name.inspect}")

        args       = step(:normalize_args) { normalize_args(aggregate, command, args) }
        step(:resolve_references) { @rules.resolve_references(domain, command, args) }
        repository = @registry.repository(domain, aggregate)
        instance   = step(:hydrate_parent) { parent(repository, aggregate, entity_name, command_name, args) }
        element    = step(:locate_element) { element_of(aggregate, entity, entity_name, command_name, instance, args) }

        view = Instance.new(aggregate: entity, id: identity_scalar(entity, element[entity.identified_by]).to_s, state: element)
        step(:enforce_givens) { @rules.enforce_givens(view, command, args) }
        transition = step(:admissible_transition) { @rules.admissible_transition(entity, command, view) }
        step(:apply_mutations) { command.mutations.each { |mutation| apply_to_element(aggregate, entity, element, mutation, args) } }
        step(:advance_lifecycle) { element[entity.lifecycle.field] = transition.target } if transition

        step(:save) { repository.save(instance) }

        [instance, step(:emit) { @rules.emit(command, domain, aggregate, instance, args, repository) }]
      end

      private

      def step(name)
        result = yield
        self.class.trace << name if self.class.trace
        result
      end

      def parent(repository, aggregate, entity_name, command_name, args)
        parent_key = aggregate.identified_by || :id
        parent_id = args[parent_key] || args[:id] ||
                    raise(NotFound, "#{command_name} acts on a #{aggregate.hecks_name}'s #{entity_name} — pass #{aggregate.identified_by}:")
        parent_id = Value.identifier(Value.for_attribute(aggregate, aggregate.attribute(parent_key), parent_id))
        repository.find(parent_id) ||
          raise(NotFound, "no #{aggregate.hecks_name} with #{aggregate.identified_by} #{parent_id.inspect}")
      end

      def element_of(aggregate, entity, entity_name, command_name, instance, args)
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, "#{aggregate.hecks_name} holds no list of #{entity_name}")
        key  = entity.identified_by
        want = args[key] ||
               raise(NotFound, "#{command_name} acts on one #{entity_name} — pass #{key}:")
        want = Value.for_attribute(aggregate, entity.attribute(key), want)

        Array(instance[list_attr.name]).find { |el| el[key] == want } ||
          raise(NotFound, "no #{entity_name} with #{key} #{identity_scalar(entity, want).to_json} on #{aggregate.hecks_name} #{instance.id.inspect}")
      end

      # An id is a SCALAR. The path says which field carries it, so a piece is
      # entry 3 — never entry {"value":3}, which is an identity nobody can type
      # back in, and which was reaching the view as a Ruby object address
      # besides. With no path the single field is still unwrapped, because a
      # value object standing as an identity has exactly one field to give.
      def identity_scalar(entity, held)
        _head, *rest = entity.identity_path.to_s.split(".")
        return Value.identifier(held) if rest.empty?

        rest.reduce(Value.materialize(held)) do |dug, field|
          dug.is_a?(Hash) ? (dug[field.to_sym] || dug[field]) : nil
        end
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
