require_relative "../../naming"
require_relative "../errors"
require_relative "../identity"
require_relative "../value"

module Hecks
  module Runtime
    module ReactionInvocation
      # Reads the receiver identity a reaction's facts carry, for an aggregate or an entity, and
      # refuses facts that name neither an identity nor a declared argument. Extended onto
      # {ReactionInvocation}.
      module Identities
        private

        # The aggregate's own identity out of the facts, else the one the event lends.
        def aggregate_identity_for(verb, target, args, inherited_receiver, consumed)
          identity, keys = identity_for(target.aggregate, args,
                                        aliases:     aggregate_aliases(target),
                                        value_owner: target.aggregate)
          identity ||= inherited_receiver
          require_identity!(verb, target.aggregate, identity)
          consumed.concat(keys)
          identity
        end

        def entity_identity(verb, entity, target, args, consumed)
          identity, keys = identity_for(entity, args,
                                        aliases:     [Naming.reference_key(entity.hecks_name)],
                                        value_owner: target.aggregate)
          require_identity!(verb, entity, identity)
          consumed.concat(keys)
          identity
        end

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

        def identity_from_alias(construct, held, value_owner)
          materialized = Value.materialize(held)
          return hash_alias_identity(construct, materialized, value_owner) if materialized.is_a?(Hash)

          materialized.to_s unless blank_identity?(materialized)
        end

        def hash_alias_identity(construct, materialized, value_owner)
          keyed = materialized.transform_keys(&:to_sym)
          nested = Identity.of(construct, keyed, value_owner: value_owner)
          return nested if nested
          return nil unless construct.identity_paths.one?

          scalar = Identity.scalar(construct.identity_paths.first, keyed)
          scalar.to_s unless blank_identity?(scalar)
        end

        def blank_identity?(value)
          value.nil? || value.to_s.empty?
        end

        def require_identity!(verb, construct, identity)
          return if identity

          raise TypeMismatch,
                "reaction target #{verb} needs #{construct.hecks_name}'s receiver identity outside command facts"
        end

        def refuse_unconsumed!(command, args, consumed, passthrough)
          allowed = consumed.map(&:to_sym) + Array(passthrough).map(&:to_sym)
          unknown = args.keys - allowed
          return if unknown.empty?

          raise UnknownArgument,
                "#{command.hecks_name} reaction projection contains neither receiver identity nor declared command facts: " \
                "#{unknown.sort.join(", ")}"
        end
      end
    end
  end
end
