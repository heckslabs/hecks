module Hecks
  module Runtime
    module EraGuard
      # Structural signature and diff of aggregate shapes, computed from the IR alone
      # (no file I/O), so the Postgres mint path can call it too.
      module ShapeDiff
        # The held and current aggregates being compared, with the lineage that may explain drift.
        Sides = Struct.new(:held_aggregate, :aggregate, :lineage)

        # Structural signature of an aggregate: sorted `[name, signature]` pairs per attribute.
        def shape(aggregate)
          aggregate.attributes.map do |attribute|
            [attribute.name, attribute_signature(aggregate, attribute.type)]
          end.sort_by(&:first)
        end

        # Expands a declared type so same-named types with different members never compare equal.
        # Primitives and references come back as-is; `seen` stops self-referencing types.
        def attribute_signature(aggregate, type_name, seen = [])
          container = nested_type(aggregate, type_name)
          return type_name if container.nil? || seen.include?(type_name)

          members = container.attributes.map do |member|
            [member.name, attribute_signature(aggregate, member.type, seen + [type_name])]
          end.sort_by(&:first)
          [type_name, members]
        end

        def nested_type(aggregate, type_name)
          aggregate.value_object(type_name) || aggregate.entities.find { |entity| entity.name == type_name }
        end

        # Names of new, non-optional attributes that no default, list, defaulted value object
        # or translation rule (`Lineage#fills?`) can fill on an existing record.
        # Destination-side check: a rename can add a name that never existed to "vanish".
        def unsafe_additions(aggregate, held_aggregate, lineage)
          held_names = held_aggregate.attributes.map(&:name)

          aggregate.attributes
                   .reject { |attribute| held_names.include?(attribute.name) }
                   .select { |attribute| possibly_absent?(aggregate, attribute) }
                   .reject { |attribute| lineage&.fills?(attribute.name.to_s) }
                   .map(&:name)
        end

        # True when a new attribute could be genuinely absent from an existing record (ADR 0025).
        def possibly_absent?(aggregate, attribute)
          return false if attribute.optional? || !attribute.default.nil? || attribute.list?

          !fully_defaulted?(aggregate.value_object(attribute.type))
        end

        # True when a value object exists and every member of it carries a default.
        def fully_defaulted?(value_object) = value_object&.attributes&.all? { |field| !field.default.nil? }

        # Held attribute paths that vanished or changed type with no rule explaining them,
        # recursing into value objects as dotted paths ("price.currency"). Additions never count.
        def uncovered_attributes(aggregate, held_aggregate, lineage)
          paths = held_aggregate.attributes.flat_map do |held_attribute|
            current_attribute = aggregate.attribute(held_attribute.name)
            next [held_attribute.name.to_s] unless current_attribute

            sides = Sides.new(held_aggregate, aggregate, lineage)
            diff_type(held_attribute.name.to_s, held_attribute.type, current_attribute.type, sides)
          end

          return paths unless lineage

          paths.reject { |path| lineage.explains?(path) }
        end

        # Compares one path's held and current types, recursing into shared members.
        # A `list_of` entity is diffed only for member drift; no per-element translation exists, so
        # only a top-level `drop` of the whole list satisfies it.
        def diff_type(path, held_type, current_type, sides, seen = [])
          return [path] if retype_drift?(held_type, current_type, sides.lineage)
          return [] if seen.include?(current_type)

          held_container = nested_type(sides.held_aggregate, held_type)
          current_container = nested_type(sides.aggregate, current_type)
          return [] unless held_container && current_container

          diff_members(path, [held_container, current_container], sides, seen + [current_type])
        end

        # A declared retype accepts the pair but members are still compared, so drift
        # hidden under the rename is caught.
        def retype_drift?(held_type, current_type, lineage)
          held_type != current_type && !lineage&.retype?(held_type, current_type)
        end

        # Diffs each member of the held container against the same-named current member.
        def diff_members(path, containers, sides, seen)
          held_container, current_container = containers
          held_container.attributes.flat_map do |held_member|
            current_member = current_container.attribute(held_member.name)
            next ["#{path}.#{held_member.name}"] unless current_member

            diff_type("#{path}.#{held_member.name}", held_member.type, current_member.type, sides, seen)
          end
        end
      end
    end
  end
end
