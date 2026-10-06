require_relative "../naming"
require_relative "errors"
require_relative "identity"
require_relative "value"

module Hecks
  module Runtime
    # Turns facts a policy or process manager selected into the receiver/payload
    # envelope an outside caller uses.
    module ReactionInvocation
      Target = Struct.new(:aggregate, :entities, :command, keyword_init: true)
      # :facts, not :values — Struct.new already defines #values (every
      # member's own value, in order); naming this field :values would
      # silently shadow that with the single Hash it actually holds.
      Scope = Struct.new(:name, :facts, keyword_init: true)

      module_function

      # Reports whether a reaction declared an explicit `with:` projection;
      # an omitted projection and an explicit `with: {}` both count as none.
      #
      # @param declaration [Bluebook::Policy, Bluebook::DispatchSpec] the reacting
      #   declaration to check
      # @return [Boolean] true if the declaration names an explicit `with:` projection
      def projection_declared?(declaration)
        if declaration.instance_variable_defined?(:@projection_declared)
          declaration.instance_variable_get(:@projection_declared)
        else
          !declaration.with_spec.to_a.empty?
        end
      end

      # Resolves a declared `with:` projection against the scopes and bindings visible
      # to it, refusing a name resolved in neither rather than passing it as nil.
      #
      # @param with_spec [Hash] fact name => source: a Symbol looked up in `bindings`/`scopes`,
      #   or any other value taken as a literal
      # @param scopes [Array<Scope, Array(String, Hash)>] named fact scopes, checked in order
      # @param bindings [Hash] explicit bindings (e.g. a saga's correlation key), checked first
      # @param label [String] names this resolution in an `UnknownArgument` refusal
      # @return [Hash] `with_spec`'s keys mapped to their resolved, materialized values
      # @raise [Runtime::UnknownArgument] if a Symbol source is visible in no binding or scope
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

      def resolved_mapping_value(source, bindings, scopes, label)
        return source unless source.is_a?(Symbol)
        return bindings.fetch(source) if bindings.key?(source)

        visible = scopes.find { |scope| scope.facts.key?(source) }
        unless visible
          names = scopes.map(&:name).join(" then ")
          # Names every visible option so a caller isn't left guessing at fields.
          offered = scopes.map { |scope| "#{scope.name}: #{scope.facts.keys.sort.join(", ")}" }.join("; ")
          raise UnknownArgument,
                "#{label}'s with: reads :#{source}, which is not visible in #{names} (visible — #{offered})"
        end
        visible.facts.fetch(source)
      end
      private_class_method :resolved_mapping_value

      # A reaction without an explicit `with:` projection forwards its payload
      # wholesale; an explicit one builds a strict `{to:, with:}` envelope instead.
      # rubocop:disable-next Metrics/MethodLength, Metrics/PerceivedComplexity
      # @param verb [String] the fully qualified target command verb
      # @param projected [Hash] resolved facts, or the raw payload when not `explicit`
      # @param explicit [Boolean] whether the reaction declared its own `with:` projection
      # @param passthrough [Array<String, Symbol>] extra fact names allowed unconsumed
      # @param source_receiver [Hash, nil] an inheritable receiver from the triggering event
      # @return [Hash] `{to:, with:}` when explicit, else `projected` merged with `to:`
      # @raise [Runtime::UnknownVerb] if `verb` does not resolve (only when `explicit`)
      # @raise [Runtime::TypeMismatch] if no receiver identity resolves for an explicit target
      # @raise [Runtime::UnknownArgument] if an explicit projection has an undeclared fact
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
          # An entity target's receiver needs `{aggregate:, entities:}`, but nothing
          # here can invent the entity's own identity — so no receiver is lifted here;
          # the payload forwards wholesale, same as with no `source_receiver` at all.
          return args unless target.entities.empty?

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

        # A port operation shares the two-segment tail shape an entity command
        # uses ("Head.Rest"); checked first, matching the order
        # `Dispatcher#dispatch` already resolves a live verb in.
        if entity_names.one? && (port = aggregate.port(entity_names.first))
          operation = port.operation(command_name)
          raise UnknownVerb, "reaction target #{verb.inspect} does not resolve to a declared port operation" unless operation

          return Target.new(aggregate: aggregate, entities: [], command: operation)
        end

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

      # An event's own identity can supply the receiver of a non-creating command on
      # the same aggregate root; it never addresses another aggregate or an entity.
      def source_receiver_for(target, source_receiver)
        return nil unless source_receiver
        # `target.command.creates?` alone misreads every entity command, which always
        # answers true for `creates?` though it never creates anything (Behaviour::
        # Command#creates?) — checked as the same compound condition `build` uses below.
        return nil if target.entities.empty? && target.command.creates?

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
              "#{unknown.sort.join(", ")}"
      end
      private_class_method :refuse_unconsumed!
    end
  end
end
