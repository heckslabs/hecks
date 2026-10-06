module Hecks
  module Bluebook
    module MetaValidator
      class Judge
        # The walk over a built bluebook: every sibling is declared before any is detailed, and
        # each node's own setters, appends, children and sealers are offered in a fixed order.
        module Walking
          private

          # Every sibling is declared before any is detailed, so one
          # sibling's attribute can reference another declared later in
          # the same file.
          def declare_node(visit, extra = {})
            plan = @plan.category(visit.category)
            return unless plan

            declare(plan, visit, identify(visit), extra)
          end

          def detail_node(visit, extra = {}, receiver: nil)
            plan = @plan.category(visit.category)
            return unless plan

            id = identify(visit)
            # `extra` carries every entity-owned ancestor's identity down to
            # this node; an ordinary category ignores it and locates its
            # record through `id:` instead, so merging it in would be
            # refused as an unrecognized argument.
            identity = extra.merge(node_identity(plan, visit))

            detail_in_order(plan, visit, id, identity, receiver || { aggregate: id, entities: [] })
          end

          # A node's own parts, in the order the language needs them offered.
          def detail_in_order(plan, visit, id, identity, receiver)
            eager, later = children_split(visit.category)

            walk_children(eager, visit, id, identity, receiver)
            setters(plan, visit, receiver)
            # Before `appends`: a nested entity referenced from this node's
            # own attribute list must exist before that list is walked.
            nest_entities(visit, id)
            appends(plan, visit, receiver)
            walk_children(later, visit, id, identity, receiver)
            within_entity(visit, id)
            sealers(plan, receiver)
          end

          # `children_of`'s order is incidental (plan registration order);
          # the eager ones keep only what EAGER_CHILDREN promises, in the order it does.
          def children_split(category)
            eager, later = children_of(category).partition { |child| eager?(category, child) }
            [Array(EAGER_CHILDREN[category]) & eager, later]
          end

          def walk_children(children, visit, id, identity, receiver)
            children.each do |child|
              walk_all(child, visit.node, id, entity_child_extra(child, identity), receiver: receiver)
            end
          end

          # Only an entity-owned child needs the accumulated ancestor
          # identity; an ordinary child dispatches through its own
          # top-level aggregate.
          def entity_child_extra(child, identity)
            @plan.category(child)&.entity_owned ? identity : {}
          end

          def walk_all(category, node, parent_id, extra = {}, receiver: nil)
            reader = collection_reader(category)
            return unless node.respond_to?(reader)

            visits = Array(node.public_send(reader)).each_with_index.map do |child, index|
              Visit.new(category, child, parent_id, index)
            end
            declare_all(visits, extra)
            detail_all(visits, extra, receiver)
          end

          def declare_all(visits, extra)
            visits.each { |visit| declare_node(visit, extra) }
          end

          def detail_all(visits, extra, receiver)
            visits.each { |visit| detail_node(visit, extra, receiver: child_receiver(visit, receiver)) }
          end

          # An entity-owned child is addressed by its root aggregate and the chain of entities
          # leading to it; any other child needs no receiver of its own.
          def child_receiver(visit, receiver)
            return unless @plan.category(visit.category)&.entity_owned

            root = receiver || { aggregate: visit.parent_id, entities: [] }
            { aggregate: root[:aggregate], entities: Array(root[:entities]) + [identify(visit)] }
          end

          # Addressed under the piece so a command name can't collide
          # between an aggregate and one of its entities; `aggregate` says
          # what a reference resolves against, `entity_id` says which
          # piece declared it.
          def within_entity(visit, id)
            return unless visit.category == "Entity"

            WITHIN_ENTITY.each do |child|
              plan = @plan.category(child)
              walk_all(child, visit.node, id, {
                         aggregate: carried(plan, plan&.declare, "aggregate", visit.parent_id),
                         entity_id: carried(plan, plan&.declare, "entity_id", id)
                       })
            end
          end

          # An entity may nest further entities (ADR 0026): `aggregate`
          # stays the walk's root, while `owner` is this entity's own
          # direct parent — what tells a nested entity apart from a
          # root-level one sharing that same root.
          def nest_entities(visit, id)
            return unless visit.category == "Entity"

            plan = @plan.category("Entity")
            walk_all("Entity", visit.node, visit.parent_id, {
                       aggregate: carried(plan, plan&.declare, "aggregate", visit.parent_id),
                       owner:     carried(plan, plan&.declare, "owner", id)
                     })
          end

          def children_of(category)
            @plan.names.select { |name| @plan.category(name).parent == category }
          end

          def eager?(category, child) = Array(EAGER_CHILDREN[category]).include?(child)

          # Command -> commands, ValueObject -> value_objects, Query ->
          # queries: convention, not a table. Naming.plural is kept as the
          # single implementation, so a second one can't disagree with it.
          def collection_reader(category) = Naming.plural(Naming.snake(category))
        end
      end
    end
  end
end
