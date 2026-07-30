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
        args       = normalize_args(domain, aggregate, command, args)
        resolve_references(domain, aggregate, command, args)
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
               raise(NotFound, "#{command.hecks_name} acts on an existing #{aggregate.name} — pass #{aggregate.identified_by}:")
          repository.find(id) || raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{id.inspect}")
        end
      end

      # A reference must point at something that EXISTS.
      #
      # `reference_to Customer` is the one guarantee an aggregate reference is
      # for, and it was declared 14 times across banking and enforced nowhere :
      # an Account could belong to a customer who was never registered, in both
      # runtimes, and parity stayed green because both were equally permissive
      # and no corpus step ever passed a dangling reference.
      #
      # Resolved here rather than in coercion because coercion is pure — it
      # holds no repository. A reference INTO ANOTHER DOMAIN is left alone : a
      # cross-domain target may legitimately not be loaded, which is the same
      # reading `across` policies already get.
      def resolve_references(domain, aggregate, command, args)
        command.attributes.each do |attribute|
          next unless attribute.reference?
          next unless args.key?(attribute.name)

          held = args[attribute.name]
          next if held.nil?

          target = referenced_aggregate(domain, attribute)
          next unless target

          key = reference_identity(held)
          next if key.to_s.empty?
          next if @registry.repository(domain, target).find(key)

          raise NotFound,
                "no #{target.name} with #{target.identified_by || :id} #{key.inspect}"
        end
      end

      # The reference RESOLVES itself — through the chapter's namespace, so Ruby's
      # constant tree is the index. This used to regex the target's name out of
      # "Reference<Customer>" and then search `registry.bluebook(domain).aggregates`
      # for it: a spelling parsed, and a registry scanned, to reach a class the
      # attribute was holding all along.
      def referenced_aggregate(_domain, attribute)
        attribute.type.resolve&.ir
      end

      def reference_identity(held)
        case held
        when Value then Value.scalar(held).to_s
        when Hash  then held.values.first.to_s
        else held.to_s
        end
      rescue TypeMismatch
        nil
      end

      def reference_key(command)
        target = command.references.to_s
        return nil if target.empty?

        Naming.reference_key(target)
      end

      # A command takes the arguments it declares, and no others. Anything else
      # used to ride along in the payload untouched — normalize_args walks the
      # DECLARED attributes, so a name the command never had was simply never
      # looked at. A misspelled argument did nothing, in silence.
      #
      # The keys that are legitimately not attributes are the ones that ADDRESS
      # the aggregate rather than describe it : `id`, whatever the aggregate is
      # identified by, and the reference key of the root a command reaches
      # through. Refusing those would refuse every dispatch there is.
      def refuse_unknown_arguments(domain, aggregate, command, args)
        addressing = [:id, aggregate.identified_by, reference_key(command)] + correlation_keys(domain)
        known      = (command.attributes.map(&:name) + addressing).compact.map(&:to_sym)
        # SORTED. Payload order is whatever the caller happened to write, and the
        # two runtimes iterate a map differently — an unsorted list makes the same
        # refusal read differently in Ruby and Rust, and parity says so.
        unknown = (args.keys.map(&:to_sym) - known).sort
        return if unknown.empty?

        raise UnknownArgument,
              "#{command.hecks_name} does not declare #{unknown.join(', ')} — " \
              "it takes #{command.attributes.map(&:name).join(', ')}"
      end

      # What a process manager correlates by is ROUTING, not description. A saga
      # threads its correlation key through every leg it dispatches so the event
      # each leg emits carries it and the next step can be correlated — so the key
      # arrives on commands that never declare it, and legitimately.
      #
      # This is the weakest part of the gate. Correlation is the SAGA's business,
      # and the better shape is for the saga to stamp its own key onto the event
      # it caused rather than smuggle it through the command's payload. Until it
      # does, refusing the key here would break every saga in the corpus.
      def correlation_keys(domain)
        Array(@registry.bluebook(domain)&.process_managers)
          .filter_map { |saga| saga.correlates_by&.to_sym }
      end

      def normalize_args(domain, aggregate, command, args)
        refuse_unknown_arguments(domain, aggregate, command, args)

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
