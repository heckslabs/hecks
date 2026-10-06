require_relative "../naming"
require_relative "errors"
require_relative "identity"
require_relative "value"
require_relative "reaction_invocation/target_resolution"
require_relative "reaction_invocation/identities"

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
        normalized_scopes = normalized_scopes(scopes)

        with_spec.to_h do |key, source|
          value = resolved_mapping_value(source, normalized_bindings, normalized_scopes, label)
          [key.to_sym, Value.materialize(value)]
        end
      end

      def normalized_scopes(scopes)
        scopes.map do |scope|
          scope = Scope.new(name: scope.first, facts: scope.last) unless scope.is_a?(Scope)
          Scope.new(name: scope.name.to_s, facts: scope.facts.transform_keys(&:to_sym))
        end
      end
      private_class_method :normalized_scopes

      def resolved_mapping_value(source, bindings, scopes, label)
        return source unless source.is_a?(Symbol)
        return bindings.fetch(source) if bindings.key?(source)

        visible = scopes.find { |scope| scope.facts.key?(source) }
        refuse_invisible!(source, scopes, label) unless visible
        visible.facts.fetch(source)
      end
      private_class_method :resolved_mapping_value

      def refuse_invisible!(source, scopes, label)
        names = scopes.map(&:name).join(" then ")
        # Names every visible option so a caller isn't left guessing at fields.
        offered = scopes.map { |scope| "#{scope.name}: #{scope.facts.keys.sort.join(", ")}" }.join("; ")
        raise UnknownArgument,
              "#{label}'s with: reads :#{source}, which is not visible in #{names} (visible — #{offered})"
      end
      private_class_method :refuse_invisible!

      # Forwards the payload wholesale, or builds a strict `{to:, with:}` envelope when explicit.
      #
      # @param verb [String] the fully qualified target command verb
      # @param projected [Hash] resolved facts, or the raw payload when not `explicit`
      # @param explicit [Boolean] whether the reaction declared its own `with:` projection
      # @param passthrough [Array<String, Symbol>] extra fact names allowed unconsumed
      # @param source_receiver [Hash, nil] an inheritable receiver from the triggering event
      # @return [Hash] `{to:, with:}` when explicit, else `projected` merged with `to:`
      # @raise [Runtime::UnknownVerb] if `verb` does not resolve (only when `explicit`)
      # @raise [Runtime::TypeMismatch] if no receiver identity resolves for an explicit target
      # @raise [Runtime::UnknownArgument] if an explicit projection has an undeclared fact
      # rubocop:disable-next Metrics/ParameterLists -- the keyword door both interpreters call
      def build(registry:, verb:, projected:, explicit:, passthrough: [], source_receiver: nil)
        args = projected.transform_keys(&:to_sym)
        return forwarded(registry, verb, args, source_receiver) unless explicit

        explicit_envelope(registry, verb, args, passthrough, source_receiver)
      end

      # A compatibility call: the payload forwards wholesale, with the triggering event's own
      # identity lent as the receiver when the target can take it.
      def forwarded(registry, verb, args, source_receiver)
        return args unless source_receiver

        # Compatibility calls still belong to Dispatcher when the target is
        # absent: it owns the canonical UnknownVerb wording. Resolution here
        # is only an optional opportunity to lift same-aggregate Event.id.
        target = optional_target(registry, verb)
        # An entity target's receiver needs `{aggregate:, entities:}`, but nothing
        # here can invent the entity's own identity — so no receiver is lifted here;
        # the payload forwards wholesale, same as with no `source_receiver` at all.
        return args unless target&.entities&.empty?

        inherited_receiver = source_receiver_for(target, source_receiver)
        inherited_receiver ? args.merge(to: inherited_receiver) : args
      end
      private_class_method :forwarded

      def optional_target(registry, verb)
        resolve_target(registry, verb)
      rescue UnknownVerb
        nil
      end
      private_class_method :optional_target

      # The strict `{to:, with:}` envelope: the declared facts, and the receiver the target's
      # identity resolves to.
      def explicit_envelope(registry, verb, args, passthrough, source_receiver)
        target = resolve_target(registry, verb)
        facts = command_facts(target.command, args)
        consumed = facts.keys

        if target.entities.empty? && target.command.creates?
          refuse_unconsumed!(target.command, args, consumed, passthrough)
          return { with: facts }
        end

        route = receiver_route(verb, target, args, source_receiver_for(target, source_receiver), consumed)
        refuse_unconsumed!(target.command, args, consumed, passthrough)
        { to: route, with: facts }
      end
      private_class_method :explicit_envelope

      # The aggregate's identity, or the aggregate's and each entity's when the target is one.
      def receiver_route(verb, target, args, inherited_receiver, consumed)
        aggregate_identity = aggregate_identity_for(verb, target, args, inherited_receiver, consumed)
        entity_identities = target.entities.map { |entity| entity_identity(verb, entity, target, args, consumed) }
        return aggregate_identity if entity_identities.empty?

        { aggregate: aggregate_identity, entities: entity_identities }
      end
      private_class_method :receiver_route

      extend TargetResolution
      extend Identities
    end
  end
end
