require_relative "../value_generator"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Gives a step's arguments the identity of the record it addresses, shaped like the
      # construct's own identity field.
      module IdentityShaping
        private

        def add_identity!(args, entry)
          aggregate = entry[:aggregate]
          if entry[:entity]
            add_entity_identity!(args, entry, aggregate)
          elsif entry[:command].creates?
            add_created_identity!(args, aggregate)
          else
            args[identity_key(aggregate)] = identity_shaped(aggregate, aggregate.identified_by,
                                                            pick_known(aggregate.hecks_name), aggregate)
          end
        end

        def identity_key(aggregate) = (aggregate.identified_by || :id).to_s

        def add_entity_identity!(args, entry, aggregate)
          parent_scalar = pick_known(aggregate.hecks_name)
          args[identity_key(aggregate)] = identity_shaped(aggregate, aggregate.identified_by, parent_scalar, aggregate)
          add_chain_identities!(args, entry, aggregate, parent_scalar)
        end

        # One identity per hop, drawn from that hop's pool (`entity_pool_key`), as
        # flat args, which is what `EntityElement#locate_chain` reads.
        def add_chain_identities!(args, entry, aggregate, parent_scalar)
          scalars = [parent_scalar]
          names   = []
          entry[:chain].each do |piece|
            names << piece.hecks_name
            scalar = pick_entity_known(entity_pool_key(aggregate.hecks_name, names, scalars))
            args[identity_key(piece)] = identity_shaped(piece, piece.identified_by, scalar, aggregate)
            scalars << scalar
          end
        end

        # A composite identity's parts are already generated as the command's own
        # attributes; a synthetic `id` would be refused as an undeclared argument.
        def add_created_identity!(args, aggregate)
          return if composite_identity?(aggregate)

          args[identity_key(aggregate)] ||= identity_shaped(aggregate, aggregate.identified_by,
                                                            ValueGenerator.random_id(@random), aggregate)
        end

        # True only for a multi-field identity: `identified_by` is also nil for the
        # untyped default, whose parts are not in `args`.
        def composite_identity?(aggregate) = aggregate.identified_by.nil? && aggregate.identity_paths.size > 1

        # Shapes a bare scalar id like the construct's identity field. A
        # value-object-typed identity given a bare scalar is a TypeMismatch, so it
        # must be wrapped; the untyped default `:id` stays bare.
        def identity_shaped(construct, key, scalar, aggregate)
          return scalar unless key

          attribute = construct.attribute(key)
          return scalar unless attribute

          value_object = aggregate.value_object(attribute.type.to_s)
          return scalar unless value_object

          field = value_object.attributes.first
          return scalar unless field

          { field.name.to_s => coerce_scalar(field.type.to_s, scalar) }
        end

        def coerce_scalar(type_name, scalar)
          case type_name
          when "Integer" then scalar.to_i
          when "Float"   then scalar.to_f
          else scalar.to_s
          end
        end
      end
    end
  end
end
