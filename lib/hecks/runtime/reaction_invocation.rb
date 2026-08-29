require_relative "../naming"
require_relative "errors"
require_relative "identity"
require_relative "value"

module Hecks
  module Runtime
    # Turns facts selected by a policy or process manager into the same
    # receiver/payload envelope an outside caller uses. Reaction declarations
    # historically selected both through one `with:` map, so this is the one
    # compatibility seam that separates receiver identities from facts after
    # resolving the declaration and before re-entering the dispatcher.
    module ReactionInvocation
      Target = Struct.new(:aggregate, :entities, :command, keyword_init: true)
      # :facts, not :values — Struct.new already defines #values (every
      # member's own value, in order); naming this field :values silently
      # shadowed that with the single Hash it actually holds.
      Scope = Struct.new(:name, :facts, keyword_init: true)

      module_function

      # The holding IR historically represented both an omitted projection and
      # an explicitly empty `with: {}` as the same empty array. Builders now
      # preserve declaration presence off-wire; reconstructed/legacy IR falls
      # back to the old non-empty reading.
      def projection_declared?(declaration)
        if declaration.instance_variable_defined?(:@projection_declared)
          declaration.instance_variable_get(:@projection_declared)
        else
          !declaration.with_spec.to_a.empty?
        end
      end

      # A reaction's source names resolve lexically, not globally. Policies
      # supply one event/row scope. Process managers supply current event then
      # opening-event memory, while correlation is an explicit binding ahead
      # of both. Missing names are refused here rather than materialized as nil
      # and accidentally presented as target command facts.
      def resolve_mapping(with_spec:, scopes:, bindings: {}, label: "reaction")
        normalized_bindings = bindings.transform_keys(&:to_sym)
        normalized_scopes = scopes.map do |scope|
          scope = Scope.new(name: scope.first, facts: scope.last) unless scope.is_a?(Scope)
          Scope.new(name: scope.name.to_s, facts: scope.facts.transform_keys(&:to_sym))
        end

        with_spec.to_h do |key, source|
          value = resolved_mapping_value(source, normalized_bindings, normalized_scopes, label)
          [key.to_sym, Value.materialize(value)]
        end
      end

      # ONE `with:` SOURCE, RESOLVED — pulled out of resolve_mapping
      # because it is a pure function of its own arguments (a literal, a
      # binding, or a name visible in some scope), with no dependency on
      # anything else resolve_mapping's own to_h block is doing.
      def resolved_mapping_value(source, bindings, scopes, label)
        return source unless source.is_a?(Symbol)
        return bindings.fetch(source) if bindings.key?(source)

        visible = scopes.find { |scope| scope.facts.key?(source) }
        unless visible
          names = scopes.map(&:name).join(" then ")
          # WHAT IS VISIBLE, NAMED. A refusal that only says which name is
          # missing sent a modeler guessing field after field
          # (`number`, `reference`…) at a fan-out row that is addressed
          # by ONE key — `account`, the lowercase aggregate — which
          # nothing else in the domain spells out. The names each scope
          # actually offers are the whole diagnosis; the refusal now
          # lists them, scope by scope.
          offered = scopes.map { |scope| "#{scope.name}: #{scope.facts.keys.sort.join(', ')}" }.join("; ")
          raise UnknownArgument,
                "#{label}'s with: reads :#{source}, which is not visible in #{names} (visible — #{offered})"
        end
        visible.facts.fetch(source)
      end
      private_class_method :resolved_mapping_value

      # A reaction without an explicit projection retains wholesale legacy
      # forwarding. Choosing `with:` opts into the strict envelope: only target
      # command attributes enter `with:`, while identities become `to:`.
      # `consumed` accumulates across the aggregate-identity and entity-
      # identity steps below, and refuse_unconsumed! at the end reads the
      # FINAL list — an ordering dependency threaded through one shared
      # local. Already leans on private helpers (identity_for,
      # source_receiver_for, command_facts, refuse_unconsumed!) for every
      # piece that IS self-contained; what remains is the sequencing
      # itself, which further splitting would only relocate, not remove.
      # rubocop:disable-next Metrics/MethodLength
      def build(registry:, verb:, projected:, explicit:, passthrough: [], source_receiver: nil)
        args = projected.transform_keys(&:to_sym)
        unless explicit
          return args unless source_receiver

          # Compatibility calls still belong to Dispatcher when the target is
          # absent: it owns the canonical UnknownVerb wording. Resolution here
          # is only an optional opportunity to lift same-aggregate Event.id.
          begin
            target = resolve_target(registry, verb)
          rescue UnknownVerb
            return args
          end
          inherited_receiver = source_receiver_for(target, source_receiver)
          return inherited_receiver ? args.merge(to: inherited_receiver) : args
        end

        target = resolve_target(registry, verb)
        inherited_receiver = source_receiver_for(target, source_receiver)
        facts = command_facts(target.command, args)
        consumed = facts.keys

        if target.entities.empty? && target.command.creates?
          refuse_unconsumed!(target.command, args, consumed, passthrough)
          return { with: facts }
        end

        aggregate_identity, aggregate_keys = identity_for(
          target.aggregate,
          args,
          aliases:     aggregate_aliases(target),
          value_owner: target.aggregate
        )
        aggregate_identity ||= inherited_receiver
        require_identity!(verb, target.aggregate, aggregate_identity)
        consumed.concat(aggregate_keys)

        entity_identities = target.entities.map do |entity|
          identity, keys = identity_for(
            entity,
            args,
            aliases:     [Naming.reference_key(entity.hecks_name)],
            value_owner: target.aggregate
          )
          require_identity!(verb, entity, identity)
          consumed.concat(keys)
          identity
        end

        refuse_unconsumed!(target.command, args, consumed, passthrough)

        route = if entity_identities.empty?
                  aggregate_identity
                else
                  { aggregate: aggregate_identity, entities: entity_identities }
                end
        { to: route, with: facts }
      end

      def resolve_target(registry, verb)
        domain, aggregate_name, command_path = Naming.split_verb(verb)
        raise UnknownVerb, "reaction target #{verb.inspect} is not a qualified command" unless command_path

        bluebook = registry.bluebook(domain)
        aggregate = bluebook&.aggregate(aggregate_name)
        raise UnknownVerb, "reaction target #{verb.inspect} does not resolve to an aggregate" unless aggregate

        *entity_names, command_name = command_path.split(".")
        owner = aggregate
        entities = entity_names.map do |entity_name|
          entity = owner.entities.find { |candidate| candidate.hecks_name == entity_name }
          raise UnknownVerb, "reaction target #{verb.inspect} does not resolve entity #{entity_name.inspect}" unless entity

          owner = entity
          entity
        end
        command = owner.command(command_name)
        raise UnknownVerb, "reaction target #{verb.inspect} does not resolve to a command" unless command

        Target.new(aggregate: aggregate, entities: entities, command: command)
      end
      private_class_method :resolve_target

      def command_facts(command, args)
        declared = command.attributes.map { |attribute| attribute.name.to_sym }
        args.slice(*declared)
      end
      private_class_method :command_facts

      def aggregate_aliases(target)
        aliases = [:aggregate, Naming.reference_key(target.aggregate.name)]
        aliases.unshift(target.command.addressing_key_for(target.aggregate.name)) if target.entities.empty?
        aliases.compact.uniq
      end
      private_class_method :aggregate_aliases

      # Event.id names the aggregate that emitted the event. It can therefore
      # supply only the receiver of a non-creating command on that SAME root;
      # it cannot address another aggregate, invent an entity identity, or turn
      # a creation into a mutation. An explicit projected receiver is resolved
      # first and remains authoritative.
      def source_receiver_for(target, source_receiver)
        return nil unless source_receiver
        return nil unless target.entities.empty?
        return nil if target.command.creates?

        source = source_receiver.transform_keys(&:to_sym)
        source_aggregate = source[:aggregate].to_s
        same_aggregate = source_aggregate == if source_aggregate.include?("::")
                                               target.aggregate.hecks_fqn
                                             else
                                               target.aggregate.hecks_name
                                             end
        return nil unless same_aggregate

        identity = source[:identity]
        identity.to_s unless identity.nil? || identity.to_s.empty?
      end
      private_class_method :source_receiver_for

      def identity_for(construct, args, aliases:, value_owner:)
        identity = Identity.of(construct, args, value_owner: value_owner)
        return [identity, construct.identity_heads] if identity

        aliases.each do |key|
          key = key.to_sym
          next unless args.key?(key)

          identity = identity_from_alias(construct, args[key], value_owner)
          return [identity, [key]] if identity
        end

        return [args[:id].to_s, [:id]] if args.key?(:id) && !args[:id].to_s.empty?

        [nil, []]
      end
      private_class_method :identity_for

      def identity_from_alias(construct, held, value_owner)
        materialized = Value.materialize(held)
        if materialized.is_a?(Hash)
          keyed = materialized.transform_keys(&:to_sym)
          nested = Identity.of(construct, keyed, value_owner: value_owner)
          return nested if nested

          if construct.identity_paths.one?
            scalar = Identity.scalar(construct.identity_paths.first, keyed)
            return scalar.to_s unless scalar.nil? || scalar.to_s.empty?
          end

          return nil
        end

        materialized.to_s unless materialized.nil? || materialized.to_s.empty?
      end
      private_class_method :identity_from_alias

      def require_identity!(verb, construct, identity)
        return if identity

        raise TypeMismatch,
              "reaction target #{verb} needs #{construct.hecks_name}'s receiver identity outside command facts"
      end
      private_class_method :require_identity!

      def refuse_unconsumed!(command, args, consumed, passthrough)
        allowed = consumed.map(&:to_sym) + Array(passthrough).map(&:to_sym)
        unknown = args.keys - allowed
        return if unknown.empty?

        raise UnknownArgument,
              "#{command.hecks_name} reaction projection contains neither receiver identity nor declared command facts: " \
              "#{unknown.sort.join(', ')}"
      end
      private_class_method :refuse_unconsumed!
    end
  end
end
