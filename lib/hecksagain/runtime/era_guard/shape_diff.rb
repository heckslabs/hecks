module Hecksagain
  module Runtime
    module EraGuard
      # The pure half: computing an aggregate's structural signature and
      # diffing two eras' shapes. No file I/O — everything here answers
      # from the IR it is handed, which is why the Postgres mint path can
      # call it too.
      module ShapeDiff
        def shape(aggregate)
          aggregate.attributes.map { |attribute| [attribute.name, attribute_signature(aggregate, attribute.type)] }.sort_by(&:first)
        end

        # A plain type name for a primitive; `[type_name, member_signatures]`
        # for a value object or entity, walked recursively — so two
        # attributes with the same declared type name but a different
        # internal shape are never mistaken for unchanged.
        def attribute_signature(aggregate, type_name, seen = [])
          container = nested_type(aggregate, type_name)
          return type_name if container.nil? || seen.include?(type_name)

          members = container.attributes.map { |member| [member.name, attribute_signature(aggregate, member.type, seen + [type_name])] }.sort_by(&:first)
          [type_name, members]
        end

        def nested_type(aggregate, type_name)
          aggregate.value_object(type_name) || aggregate.entities.find { |entity| entity.name == type_name }
        end

        # Paths the translation needs to explain: attributes that vanished
        # by name, attributes that kept their name but changed type (a
        # `convert` is what lets that be declared at all), and — recursing
        # into a same-named, same-typed value object — its OWN members
        # vanishing or changing type one level down, reported as a dotted
        # path ("price.currency"). A pure addition, at any depth, never
        # needs covering; only vanish-or-retype does, matching the
        # top-level rule at every depth.
        def uncovered_attributes(aggregate, held_aggregate, lineage)
          paths = held_aggregate.attributes.flat_map do |held_attribute|
            current_attribute = aggregate.attribute(held_attribute.name)
            next [held_attribute.name.to_s] unless current_attribute

            diff_type(held_attribute.name.to_s, held_attribute.type, current_attribute.type, held_aggregate, aggregate, lineage)
          end

          return paths unless lineage

          paths.reject { |path| lineage.explains?(path) }
        end

        # `held_type`/`current_type` are type NAMES, resolved against each
        # side's OWN value_object AND entity declarations — neither is ever
        # nested in the DSL, only in the type graph, so both are always
        # looked up flat off their respective aggregate. A `list_of` entity
        # is only reached here to DETECT a member vanish-or-retype; there is
        # no per-element translation machinery yet (`move`/`convert`/`drop`
        # only reach into a single nested hash, not each element of an
        # array) — the only way to satisfy a refusal on an entity path
        # today is a top-level `drop` of the whole list attribute, which
        # `explains?` already recognizes as covering everything nested
        # under it. Blunt, but loud beats silent.
        def diff_type(path, held_type, current_type, held_aggregate, aggregate, lineage, seen = [])
          if held_type != current_type
            # A declared retype says the two TYPE names mean the same shape
            # — accept the pair, but still recurse into the members so a
            # member drift hiding beneath the rename is caught by name.
            return [path] unless lineage&.retype?(held_type, current_type)
          end
          return [] if seen.include?(current_type)

          held_container = nested_type(held_aggregate, held_type)
          current_container = nested_type(aggregate, current_type)
          return [] unless held_container && current_container

          held_container.attributes.flat_map do |held_member|
            current_member = current_container.attribute(held_member.name)
            next ["#{path}.#{held_member.name}"] unless current_member

            diff_type("#{path}.#{held_member.name}", held_member.type, current_member.type, held_aggregate, aggregate, lineage, seen + [current_type])
          end
        end
      end
    end
  end
end
