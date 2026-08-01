
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

        view = Instance.new(aggregate: entity, id: element_identity(entity, element).to_s, state: element)
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

      # THE PARENT AGGREGATE, addressed exactly as `CommandInterpreter#hydrate`
      # addresses one acting on itself — derive from the declared identity first
      # (`Identity.of`), and let a bare `id:` name an already-derived record when
      # the identity itself is not what the caller is holding.
      def parent(repository, aggregate, entity_name, command_name, args)
        parent_id = Identity.of(aggregate, args) ||
                    Identity.from(aggregate, args, :id) ||
                    raise(NotFound, "#{command_name} acts on a #{aggregate.hecks_name}'s #{entity_name} — pass #{Identity.reading(aggregate)}:")
        repository.find(parent_id) ||
          raise(NotFound, "no #{aggregate.hecks_name} with #{Identity.reading(aggregate)} #{parent_id.inspect}")
      end

      # ONE ELEMENT, MATCHED ON EVERY PART OF ITS IDENTITY — not just the first.
      # A piece's identity may be several paths, the same shape a head's can be,
      # so a dispatch that names the element has to supply every part and every
      # part has to agree with the stored one.
      def element_of(aggregate, entity, entity_name, command_name, instance, args)
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, "#{aggregate.hecks_name} holds no list of #{entity_name}")

        wants = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          raw  = args[head] ||
                 raise(NotFound, "#{command_name} acts on one #{entity_name} — pass #{Identity.reading(entity)}:")

          [head, path, Value.for_attribute(aggregate, entity.attribute(head), raw)]
        end

        Array(instance[list_attr.name]).find { |el| wants.all? { |head, _path, want| el[head] == want } } ||
          raise(NotFound, "no #{entity_name} with #{Identity.reading(entity)} " \
                          "#{wants.map { |_h, path, want| Identity.scalar(path, want) }.join(', ')} " \
                          "on #{aggregate.hecks_name} #{instance.id.inspect}")
      end

      # THE ELEMENT'S OWN IDENTITY, joined from its parts — the entity-level
      # twin of `Identity.of`, reading off the STORED ELEMENT (a Hash) rather
      # than a dispatch payload. An id is a SCALAR, and the PATH is how it is
      # reached — never by opening a value object and taking whatever single
      # field is inside. That unwrapping is gone from the language : a piece
      # that does not name its fields is refused when the bluebook loads ("an
      # entity says what it is known by", "an identity part reaches a scalar"),
      # so by the time a dispatch arrives here there is always a path to dig.
      def element_identity(entity, element)
        parts = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          Identity.scalar(path, element[head])
        end

        Naming.identity(parts)
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

          Value.refuse_object_reference(command, attribute, normalized[attribute.name])
          normalized[attribute.name] = Value.for_attribute(aggregate, attribute, normalized[attribute.name])
        end
      end
    end
  end
end
