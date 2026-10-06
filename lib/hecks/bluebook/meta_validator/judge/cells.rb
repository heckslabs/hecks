module Hecks
  module Bluebook
    module MetaValidator
      class Judge
        # What one cell of an appended list is offered as: an attribute's type as the id of the
        # value object it names, a reference as the head it points at, a default as a literal.
        module Cells
          private

          # An entity has no value objects of its own; its attributes
          # resolve against its enclosing aggregate's pool, so the root
          # aggregate id (`parent_id`, not the direct parent) is what this
          # returns for it.
          def owning_aggregate_ref(category, id, parent_id)
            category == "Entity" ? parent_id : id
          end

          # An attribute's type is offered as the id of the value object it
          # names, so "attributes must use value-object types" is enforced
          # by reference resolution rather than a predicate — for an
          # entity's own attributes too, since an entity is its own root.
          def cell(category, item, append, field)
            value = row_value(item.row, field)
            # A default keeps its type by being written as a literal (0.0,
            # not "0.0"): the language holds it as text, and text alone forgets.
            return encode_literal(value) if field == :default
            return value unless field == :type
            # A reference names another head wherever it's written (on a
            # head, a command, a piece, or an ask), so it's offered as that
            # head's id in all four; only a head's own attributes further
            # qualify a plain type into a value object's id.
            return points_at(item.row, item.id) if append.verb == "Reference"
            return value unless attribute_list?(category, item.list_name)

            Naming.identity([owning_aggregate_id(item.owner_id, value), value])
          end

          # A head's own attributes (an aggregate's, or an entity's own
          # root). Every other "attributes" list belongs to something that
          # isn't a head, so a type written there is a name, not a reference.
          def attribute_list?(category, list_name)
            list_name.to_s == "attributes" && %w[Aggregate Entity].include?(category)
          end

          # A value object's type may be declared on a different aggregate
          # in the same chapter; the local aggregate is tried first, then
          # the first (declaration-order) other aggregate that declares it.
          def owning_aggregate_id(id, value)
            local = @bluebook.aggregates.find { |aggregate| Naming.identity([@bluebook.name, aggregate.name]) == id }
            return id unless local
            return id if names?(local, value)

            owner = @bluebook.aggregates.find { |aggregate| aggregate != local && names?(aggregate, value) }
            return id unless owner

            Naming.identity([@bluebook.name, owner.name])
          end

          # Checks both value objects and entities this aggregate declares:
          # the caller already knows which verb it dispatches, not which
          # collection to search, without re-deriving that here.
          def names?(aggregate, value)
            aggregate.value_objects.any? { |vo| vo.hecks_name == value } ||
              aggregate.entities.any? { |entity| entity.hecks_name == value }
          end

          # The row itself decides which verb an attribute belongs to:
          # Attribute for a value-object type, Reference<X> for another
          # aggregate's head, Holds for an entity this aggregate declares.
          # Each alternate carries its own field map — borrowing the
          # primary's would dispatch `type:` where Reference declares
          # `points_at:`.
          def append_for(category, list_name, append, row, node)
            return append unless list_name.to_s == "attributes"
            return alternate(category, "Reference") || append if reference_row?(row)
            return alternate(category, "Holds") || append if entity_row?(row, node)

            append
          end

          def alternate(category, verb)
            @plan.category(category).alternates.find { |append| append.verb == verb }
          end

          def reference_row?(row) = row.respond_to?(:reference?) && row.reference?

          # Only a head declares pieces; since every attribute list reaches
          # here now, `node` may be a command, a piece or an ask, none of
          # which answer `entities`.
          def entity_row?(row, node)
            return false unless node.respond_to?(:entities)

            Array(node.entities).any? { |entity| entity.hecks_name == row.type.to_s }
          end
        end
      end
    end
  end
end
