module Hecks
  module Bluebook
    module MetaValidator
      # Offers every declaration in a built bluebook to the meta-domain by
      # walking the plan itself, so no verb the language declares can go
      # un-offered by omission.
      class Judge
        include Readings

        # ValueObject before Entity: an entity's own attributes may
        # reference a value object, which must exist before it resolves.
        EAGER_CHILDREN = { "Aggregate" => %w[ValueObject Entity] }.freeze

        # Command and Query are reused for a piece's own commands/queries,
        # since the plan derives a category's parent from its creating
        # command's one `*_id` argument and cannot express a second parent.
        WITHIN_ENTITY = %w[Command Query].freeze

        attr_reader :refusals

        # The runtime dispatched into, not just the refusals, so a caller
        # can read the resulting records back out.
        attr_reader :runtime

        def initialize(bluebook)
          @bluebook = bluebook
          @refusals = []
          @runtime  = MetaValidator.fresh_runtime
          @plan     = Plan.for(MetaValidator.grammar_registry)
          judge!
        end

        private

        # nil stays nil so an optional field reads as undeclared rather
        # than declared-empty; an Integer passes through raw so a typed
        # field (RowCount's `value`) still hits its own type gate.
        def v(text)
          return nil if text.nil?
          return { value: text } if text.is_a?(Integer)

          { value: text.to_s }
        end

        # A reference argument is passed as the bare id it names; every
        # other field is wrapped as a one-field value object instead.
        def carried(plan, verb, argument, value)
          return v(value) unless plan && verb && plan.references?(verb, argument)

          value
        end

        def args(pairs) = pairs.compact

        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation,
               Runtime::TypeMismatch, Runtime::NotFound => e
          # NotFound is a verdict, not noise: an attribute's type is a
          # reference to its value object, so "no ValueObject with id ..."
          # is `attributes must use value-object types` refusing.
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::UnknownVerb
          nil
        end

        # Wrapped in judge_bootstrapping: the walk's own values sometimes
        # arrive as raw types a real domain command would never accept,
        # and only a judge's own dispatch should relax for that.
        def send_to(verb, label, to: nil, **payload)
          Runtime::Value.judge_bootstrapping do
            offer(label) { @runtime.dispatch(verb, to: to, with: args(payload)) }
          end
        end

        # A bare id when there is no entity hop (the common case); the
        # full {aggregate:, entities:} envelope only when there is one.
        def address(receiver)
          return receiver[:aggregate] if receiver[:entities].empty?

          receiver
        end

        def judge!
          declare_node("Bluebook", @bluebook, nil, 0)
          detail_node("Bluebook", @bluebook, nil, 0)
        end

        # Every sibling is declared before any is detailed, so one
        # sibling's attribute can reference another declared later in
        # the same file.
        def declare_node(category, node, parent_id, index, extra = {}, receiver: nil)
          plan = @plan.category(category)
          return unless plan

          declare(plan, category, node, identify(category, parent_id, node, index), parent_id, index, extra)
        end

        def detail_node(category, node, parent_id, index, extra = {}, receiver: nil)
          plan = @plan.category(category)
          return unless plan

          id = identify(category, parent_id, node, index)
          # `extra` carries every entity-owned ancestor's identity down to
          # this node; an ordinary category ignores it and locates its
          # record through `id:` instead, so merging it in would be
          # refused as an unrecognized argument.
          identity     = extra.merge(node_identity(plan, category, node, index, parent_id))
          receiver   ||= { aggregate: id, entities: [] }
          eager, later = children_of(category).partition { |child| eager?(category, child) }
          # `children_of`'s order is incidental (plan registration order);
          # keep only what EAGER_CHILDREN promises, in the order it does.
          eager = Array(EAGER_CHILDREN[category]) & eager

          eager.each { |child| walk_all(child, node, id, entity_child_extra(child, identity), receiver: receiver) }
          setters(plan, category, node, receiver)
          # Before `appends`: a nested entity referenced from this node's
          # own attribute list must exist before that list is walked.
          nest_entities(category, node, id, parent_id)
          appends(plan, category, node, receiver, parent_id)
          later.each { |child| walk_all(child, node, id, entity_child_extra(child, identity), receiver: receiver) }
          within_entity(category, node, id, parent_id)
          sealers(plan, category, receiver)
        end

        # Only an entity-owned child needs the accumulated ancestor
        # identity; an ordinary child dispatches through its own
        # top-level aggregate.
        def entity_child_extra(child, identity)
          @plan.category(child)&.entity_owned ? identity : {}
        end

        # Each identity field comes from one of three places: the parent
        # link, the walk's own index (POSITION), or a real field read off
        # the node.
        def node_identity(plan, category, node, index, parent_id)
          plan.identity_paths.each_with_object({}) do |path, fields|
            head = path.to_s.split(".").first
            next if head == OWNER

            if head == POSITION
              fields[head.to_sym] = v(index)
            else
              raw = head == plan.parent_key.to_s ? parent_id : field_value(category, node, head.to_sym, parent_id)
              fields[head.to_sym] = carried(plan, plan.declare, head, raw)
            end
          end
        end

        # An ordinary category's own top-level aggregate reaches every
        # verb bare; an entity-owned one prefixes its parent's own dotted
        # path instead (ADR 0026), since a nested entity's parent may
        # itself be entity-owned.
        def dotted_prefix(plan)
          return plan.name unless plan.entity_owned

          "#{dotted_prefix(@plan.category(plan.parent))}.#{plan.name}"
        end

        # Entity-owned categories have no top-level aggregate to route a
        # bare verb into, so the verb is addressed by this category's
        # full dotted path instead.
        def verb_for(plan, verb)
          "#{dotted_prefix(plan)}.#{verb}"
        end

        def walk_all(category, node, parent_id, extra = {}, receiver: nil)
          reader = collection_reader(category)
          return unless node.respond_to?(reader)

          children = Array(node.public_send(reader))
          children.each_with_index { |child, index| declare_node(category, child, parent_id, index, extra) }
          children.each_with_index do |child, index|
            child_plan = @plan.category(category)
            child_receiver = if child_plan&.entity_owned
                               child_id = identify(category, parent_id, child, index)
                               root = receiver || { aggregate: parent_id, entities: [] }
                               { aggregate: root[:aggregate], entities: Array(root[:entities]) + [child_id] }
                             end
            detail_node(category, child, parent_id, index, extra, receiver: child_receiver)
          end
        end

        # Addressed under the piece so a command name can't collide
        # between an aggregate and one of its entities; `aggregate` says
        # what a reference resolves against, `entity_id` says which
        # piece declared it.
        def within_entity(category, node, id, aggregate)
          return unless category == "Entity"

          WITHIN_ENTITY.each do |child|
            plan = @plan.category(child)
            walk_all(child, node, id, {
                       aggregate: carried(plan, plan&.declare, "aggregate", aggregate),
                       entity_id: carried(plan, plan&.declare, "entity_id", id)
                     })
          end
        end

        # An entity may nest further entities (ADR 0026): `aggregate`
        # stays the walk's root, while `owner` is this entity's own
        # direct parent — what tells a nested entity apart from a
        # root-level one sharing that same root.
        def nest_entities(category, node, id, aggregate)
          return unless category == "Entity"

          plan = @plan.category("Entity")
          walk_all("Entity", node, aggregate, {
                     aggregate: carried(plan, plan&.declare, "aggregate", aggregate),
                     owner:     carried(plan, plan&.declare, "owner", id)
                   })
        end

        # Where a node sits among siblings is a fact about the walk, not
        # the node, so the walk supplies it rather than reading a stored
        # field; Reconstruction depends on this being the source order.
        # `private` above has no effect on a constant; kept here anyway,
        # beside the method that reads it.
        # rubocop:disable-next Lint/UselessConstantScoping
        POSITION = "position".freeze

        def declare(plan, category, node, id, parent_id, index, extra = {})
          return unless plan.declare

          payload = {}
          payload[plan.parent_key.to_sym] = carried(plan, plan.declare, plan.parent_key, parent_id) if plan.parent_key
          plan.fields.each do |field|
            payload[field.to_sym] = if field == POSITION
                                      v(index)
                                    else
                                      carried(plan, plan.declare, field, field_value(category, node, field.to_sym, parent_id))
                                    end
          end

          send_to("Bluebook::#{verb_for(plan, plan.declare)}", id, to: id, **payload.merge(extra))
        end

        # A setter whose every source is absent is not dispatched —
        # offering "" would make a rule refuse a bluebook that is
        # well-formed.
        def setters(plan, category, node, receiver)
          plan.setters.each do |setter|
            payload = setter.targets.to_h do |target, argument|
              [argument.to_sym, v(setter_value(category, node, target))]
            end
            next if payload.values.all?(&:nil?)

            send_to("Bluebook::#{verb_for(plan, setter.verb)}", receiver[:aggregate], to: address(receiver), **payload)
          end
        end

        def appends(plan, category, node, receiver, parent_id)
          id = receiver[:entities].last || receiver[:aggregate]
          owner_id = owning_aggregate_ref(category, id, parent_id)
          plan.appends.each do |list_name, append|
            rows_for(category, list_name, node).each_with_index do |row, index|
              chosen = append_for(category, list_name, append, row, node)
              # `position` is the walk index, as in `declare`: an appended
              # element is ordered by where the walk found it.
              payload = chosen.map.to_h do |field, argument|
                value = if field.to_s == POSITION
                          v(index)
                        else
                          carried(@plan.category(category), chosen.verb, argument,
                                  cell(category, list_name, row, field, id, chosen, owner_id))
                        end
                [argument.to_sym, value]
              end

              send_to("Bluebook::#{verb_for(plan, chosen.verb)}", "#{id}##{list_name}[#{index}]",
                      to: address(receiver), **payload)
            end
          end
        end

        # An entity has no value objects of its own; its attributes
        # resolve against its enclosing aggregate's pool, so the root
        # aggregate id (`parent_id`, not the direct parent) is what this
        # returns for it.
        def owning_aggregate_ref(category, id, parent_id)
          category == "Entity" ? parent_id : id
        end

        def sealers(plan, _category, receiver)
          id = receiver[:entities].last || receiver[:aggregate]
          plan.sealers.each { |verb| send_to("Bluebook::#{verb_for(plan, verb)}", id, to: address(receiver)) }
        end

        # An attribute's type is offered as the id of the value object it
        # names, so "attributes must use value-object types" is enforced
        # by reference resolution rather than a predicate — for an
        # entity's own attributes too, since an entity is its own root.
        def cell(category, list_name, row, field, id, append, aggregate_id)
          value = row_value(row, field)
          # A default keeps its type by being written as a literal (0.0,
          # not "0.0"): the language holds it as text, and text alone forgets.
          return encode_literal(value) if field == :default
          return value unless field == :type
          # A reference names another head wherever it's written (on a
          # head, a command, a piece, or an ask), so it's offered as that
          # head's id in all four; only a head's own attributes further
          # qualify a plain type into a value object's id.
          return points_at(row, id) if append.verb == "Reference"
          return value unless attribute_list?(category, list_name)

          Naming.identity([owning_aggregate_id(aggregate_id, value), value])
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

        # A record's id is its declared identity, joined the same way the
        # runtime joins it, so there is exactly one way to name a thing.
        # Each part comes from the parent link, the walk index
        # (`position`), or a field read off the node.
        def identify(category, parent_id, node, index)
          plan = @plan.category(category)
          return declared_name(node) unless plan

          Naming.identity(plan.identity_paths.map { |path| identity_part(plan, path, parent_id, node, index, category) })
        end

        # `owner_id` is a second reserved head (beside `position`): it
        # names whichever record is walking this one right now, aggregate
        # or entity, so Command/Query address the right piece. It is
        # never a declared attribute, so it can't be read through
        # `field_value`.
        # `private` above has no effect on a constant; kept here anyway,
        # beside the method that reads it.
        # rubocop:disable-next Lint/UselessConstantScoping
        OWNER = "owner_id".freeze

        def identity_part(plan, path, parent_id, node, index, category)
          head = path.to_s.split(".").first
          return parent_id.to_s if head == plan.parent_key.to_s || head == OWNER
          return index.to_s     if head == POSITION

          v_scalar(field_value(category, node, head.to_sym, parent_id))
        end

        # The scalar inside whatever the reading handed back: a name is
        # already one, a value object is not.
        def v_scalar(held)
          return held.to_s unless held.respond_to?(:to_h) && !held.is_a?(String)

          held.to_h.values.first.to_s
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
