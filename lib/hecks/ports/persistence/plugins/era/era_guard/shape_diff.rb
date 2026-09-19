module Hecks
  module Runtime
    module EraGuard
      # The pure half: computing an aggregate's structural signature and
      # diffing two eras' shapes. No file I/O — everything here answers
      # from the IR it is handed, which is why the Postgres mint path can
      # call it too.
      module ShapeDiff
        # Computes an aggregate's structural signature, for comparing two eras of it.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate to describe
        # @return [Array<Array>] one `[name, signature]` pair per attribute, sorted by name;
        #   `name` is a Symbol and `signature` is whatever `attribute_signature` returns
        def shape(aggregate)
          aggregate.attributes.map do |attribute|
            [attribute.name, attribute_signature(aggregate, attribute.type)]
          end.sort_by(&:first)
        end

        # Expands a declared type into a signature that exposes its members.
        #
        # A plain type name for a primitive; `[type_name, member_signatures]`
        # for a value object or entity, walked recursively — so two
        # attributes with the same declared type name but a different
        # internal shape are never mistaken for unchanged.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate whose value objects and entities
        #   are searched for `type_name`
        # @param type_name [String, Bluebook::Reference] the attribute's declared type
        # @param seen [Array<String, Bluebook::Reference>] types already being expanded, which
        #   stops a self-referencing type from recursing forever
        # @return [String, Bluebook::Reference, Array] `type_name` itself for a primitive, a
        #   reference, or a type already in `seen`; otherwise `[type_name, members]`, where
        #   `members` is an Array of `[member_name, signature]` pairs sorted by member name
        def attribute_signature(aggregate, type_name, seen = [])
          container = nested_type(aggregate, type_name)
          return type_name if container.nil? || seen.include?(type_name)

          members = container.attributes.map do |member|
            [member.name, attribute_signature(aggregate, member.type, seen + [type_name])]
          end.sort_by(&:first)
          [type_name, members]
        end

        # Looks a type name up among an aggregate's value objects, then its entities.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate to search
        # @param type_name [String, Bluebook::Reference] the declared type to find
        # @return [Bluebook::ValueObject, Bluebook::Entity, nil] the matching declaration; nil
        #   when the type is a primitive, a reference, or nothing this aggregate declares
        def nested_type(aggregate, type_name)
          aggregate.value_object(type_name) || aggregate.entities.find { |entity| entity.name == type_name }
        end

        # Lists the new attributes that would leave an existing record with a required gap.
        #
        # Attributes present now that the held shape never had — the
        # addition side of drift, which `uncovered_attributes` below never
        # looks at, since it only walks the held shape (vanish/retype).
        # Most additions are free (ADR 0025, "Added attributes and
        # absence"): a default:, a list_of (frozen []), or a value object
        # whose fields all default fill an existing record automatically
        # via `Instance.hydrate_with_defaults`. Only the fourth case — a
        # non-optional attribute with no way to fill itself — can leave an
        # existing record with the field genuinely absent, and that is
        # what this reports: unfilled by a declared translation's own
        # `backfill`, or by a move/convert that lands an old field inside
        # this brand-new attribute (`Lineage#fills?` — the destination-
        # side question, never `explains?`'s source-side one, since a
        # rename from Crate to Bin can introduce a top-level attribute
        # name that never existed to have "vanished").
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate as currently declared
        # @param held_aggregate [Bluebook::Aggregate] the same aggregate as the held era's text
        #   declares it
        # @param lineage [Ports::Persistence::Lineage, nil] the edge's rules for this aggregate; nil
        #   when the edge declares none, so nothing can fill an addition
        # @return [Array<Symbol>] names of new, non-optional attributes with no default, no
        #   list cardinality, no fully-defaulted value object and no rule filling them; `[]`
        #   when every addition is safe
        def unsafe_additions(aggregate, held_aggregate, lineage)
          held_names = held_aggregate.attributes.map(&:name)

          aggregate.attributes
                   .reject { |attribute| held_names.include?(attribute.name) }
                   .select { |attribute| possibly_absent?(aggregate, attribute) }
                   .reject { |attribute| lineage&.fills?(attribute.name.to_s) }
                   .map(&:name)
        end

        # Decides whether a new attribute could be genuinely absent from an existing record.
        #
        # The four-row table, as a predicate over the fourth row only — the
        # other three (default:, list_of, a fully-defaulted value object)
        # all fill an existing record for free and never reach here.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate declaring the attribute, searched
        #   for the value object its type may name
        # @param attribute [Bluebook::Attribute] the newly added attribute
        # @return [Boolean] false when the attribute is optional, has a default, is a list, or
        #   is a value object whose every field has a default; true otherwise
        def possibly_absent?(aggregate, attribute)
          return false if attribute.optional?
          return false unless attribute.default.nil?
          return false if attribute.list?

          value_object = aggregate.value_object(attribute.type)
          return false if value_object&.attributes&.all? { |field| !field.default.nil? }

          true
        end

        # Lists the held paths that vanished or changed type with no rule explaining them.
        #
        # Paths the translation needs to explain: attributes that vanished
        # by name, attributes that kept their name but changed type (a
        # `convert` is what lets that be declared at all), and — recursing
        # into a same-named, same-typed value object — its own members
        # vanishing or changing type one level down, reported as a dotted
        # path ("price.currency"). A pure addition, at any depth, never
        # needs covering; only vanish-or-retype does, matching the
        # top-level rule at every depth.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate as currently declared
        # @param held_aggregate [Bluebook::Aggregate] the same aggregate as the held era's text
        #   declares it
        # @param lineage [Ports::Persistence::Lineage, nil] the edge's rules for this aggregate; nil
        #   when the edge declares none, so every vanished or retyped path is reported
        # @return [Array<String>] bare attribute names and dotted member paths such as
        #   `"price.currency"`; `[]` when the whole diff is explained
        def uncovered_attributes(aggregate, held_aggregate, lineage)
          paths = held_aggregate.attributes.flat_map do |held_attribute|
            current_attribute = aggregate.attribute(held_attribute.name)
            next [held_attribute.name.to_s] unless current_attribute

            diff_type(held_attribute.name.to_s, held_attribute.type, current_attribute.type, held_aggregate, aggregate, lineage)
          end

          return paths unless lineage

          paths.reject { |path| lineage.explains?(path) }
        end

        # Compares one path's held and current types, recursing into shared members.
        #
        # `held_type`/`current_type` are type names, resolved against each
        # side's own value_object and entity declarations — neither is ever
        # nested in the DSL, only in the type graph, so both are always
        # looked up flat off their respective aggregate. A `list_of` entity
        # is only reached here to detect a member vanish-or-retype; there is
        # no per-element translation machinery yet (`move`/`convert`/`drop`
        # only reach into a single nested hash, not each element of an
        # array) — the only way to satisfy a refusal on an entity path
        # today is a top-level `drop` of the whole list attribute, which
        # `explains?` already recognizes as covering everything nested
        # under it. Blunt, but loud beats silent.
        #
        # @param path [String] the bare or dotted path being compared, reported on a mismatch
        # @param held_type [String, Bluebook::Reference] the type the held era declares there
        # @param current_type [String, Bluebook::Reference] the type declared there now
        # @param held_aggregate [Bluebook::Aggregate] the held aggregate, searched for
        #   `held_type`'s declaration
        # @param aggregate [Bluebook::Aggregate] the current aggregate, searched for
        #   `current_type`'s declaration
        # @param lineage [Ports::Persistence::Lineage, nil] the edge's rules, asked whether a retype
        #   pairs the two type names; nil means no retype is accepted
        # @param seen [Array<String, Bluebook::Reference>] current types already being
        #   expanded, which stops a self-referencing type from recursing forever
        # @return [Array<String>] `[path]` when the types differ with no retype declared; the
        #   dotted paths of members that vanished or changed type beneath it; `[]` when
        #   nothing differs or either type is not a value object or entity
        def diff_type(path, held_type, current_type, held_aggregate, aggregate, lineage, seen = [])
          if held_type != current_type
            # A declared retype says the two type names mean the same shape
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

            diff_type("#{path}.#{held_member.name}", held_member.type, current_member.type, held_aggregate, aggregate, lineage,
                      seen + [current_type])
          end
        end
      end
    end
  end
end
