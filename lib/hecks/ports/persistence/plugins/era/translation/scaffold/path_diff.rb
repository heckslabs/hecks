module Hecks
  module Translation
    module Scaffold
      # The path-level half of `Differ`: which held and current attribute paths need explaining,
      # and how a type signature is compared.
      module PathDiff
        # Held paths that need explaining: vanished attributes, and members that vanished or
        # changed type inside a kept attribute — the set EraGuard demands coverage for.
        # Returns each path (dotted for a member) valued by its type signature.
        def vanished_paths(held_attrs, current_attrs, retyped) = unmatched_paths(held_attrs, current_attrs, retyped)

        # Current paths that need explaining; the mirror of `vanished_paths`.
        def appeared_paths(held_attrs, current_attrs, retyped) = unmatched_paths(current_attrs, held_attrs, retyped)

        # Appeared paths type-compatible with a vanished path's signature.
        def compatible_candidates(appeared, signature)
          appeared.select { |_, candidate| scalar_of(candidate) == scalar_of(signature) }.keys
        end

        # Reduces a type signature to what `compatible_candidates` compares: members or the scalar.
        def scalar_of(signature) = signature.is_a?(Hash) ? signature["members"] : signature

        # A container attribute's members keyed by name; `{}` for a scalar.
        def members_of(attribute)
          return {} unless container?(attribute)

          attribute["type"]["members"].to_h { |member| [member["name"], member["type"]] }
        end

        # Whether the attribute's type is a container (value object or entity), not a scalar.
        def container?(attribute) = attribute["type"].is_a?(Hash)

        # Paths in `attrs` that `others` lacks or holds differently: a whole attribute with no
        # counterpart, or each member of a kept attribute that vanished or changed type.
        def unmatched_paths(attrs, others, retyped)
          attrs.each_with_object({}) do |(name, attribute), paths|
            next if retyped.include?(container?(attribute) ? attribute["type"]["type"] : nil)

            other = others[name]
            if other.nil?
              paths[name] = attribute["type"]
            elsif attribute != other
              paths.merge!(member_drift(name, attribute, other))
            end
          end
        end

        # The dotted member paths of `attribute` that `other` lacks or types differently.
        def member_drift(name, attribute, other)
          other_members = members_of(other)
          members_of(attribute).reject { |member, signature| other_members[member] == signature }
                               .transform_keys { |member| "#{name}.#{member}" }
        end
      end
    end
  end
end
