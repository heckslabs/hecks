module Hecksagain
  module Bluebook
    module MetaValidator
      # Offers every declaration in a built bluebook to the meta-domain.
      #
      # This used to be one hand-written branch per category, and the cost of that
      # shape was fourteen verbs the language declared and the judge never offered
      # — among them `Command.Argument` and `ValueObject.Field`, so a command's own
      # arguments and a value object's own fields were NEVER judged. Every rule
      # hanging off them was decoration. Nothing went red, because a branch that
      # does not exist cannot fail.
      #
      # So there are no branches. The judge WALKS: it reads the plan the language
      # makes of itself (Plan), and for each node offers the creating command, then
      # each list through the command that appends to it, then each child. A verb
      # in the plan with no offer is now impossible — there is no branch left in
      # which to forget one, and spec/judge_coverage_spec holds it to that.
      #
      # What is NOT uniform lives in Readings, and only where the IR's SHAPE
      # differs from the language's. Naming differences do not appear at all: the
      # language spells its fields as the IR spells them.
      #
      # Only the DISPATCH half of the round trip lives here. Reconstruction is the
      # experiment's business ; judging does not need it.
      class Judge
        include Readings

        # Children offered BEFORE the parent's own lists. An attribute's type is
        # offered as the id of the thing it names, so both the value objects and the
        # entities have to exist before any attribute names one.
        EAGER_CHILDREN = { "Aggregate" => %w[Entity ValueObject] }.freeze

        # Categories an ENTITY declares as well as an aggregate. The IR reuses
        # IR::Command and IR::Query for a piece's own commands and queries, so the
        # language reuses Command and Query — and the plan cannot express a second
        # parent, because a category's parent is derived from the one `*_id` argument
        # its creating command carries. This says the other edge out loud.
        WITHIN_ENTITY = %w[Command Query].freeze

        attr_reader :refusals

        # THE RECORDS SURVIVE THE VERDICT.
        #
        # Judging a bluebook and HOLDING one differ by exactly this: whether anyone
        # keeps the runtime the declarations were dispatched into. Nobody did, so
        # `spec/round_trip_spec` reached the records by `Judge.allocate` and four
        # `instance_variable_set` calls. Reading the chapter back is the point now,
        # not a curiosity, so the runtime is simply readable.
        attr_reader :runtime

        def initialize(bluebook)
          @bluebook = bluebook
          @refusals = []
          @runtime  = MetaValidator.fresh_runtime
          @plan     = Plan.for(MetaValidator.grammar_registry)
          judge!
        end

        private

        # ABSENT is not EMPTY. The rules read "if you declare it, declare
        # something" — a description never given is legal. Passing "" for a nil
        # turns every one of them into "you must declare it".
        #
        # An Integer stays an Integer : RowCount declares `attribute :value,
        # Integer`, so stringifying a member count fails the type gate rather than
        # feeding the rule it was meant to feed.
        def v(text)
          return nil if text.nil?
          return { value: text } if text.is_a?(Integer)

          { value: text.to_s }
        end

        def args(pairs) = pairs.reject { |_, value| value.nil? }

        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation,
               Runtime::TypeMismatch, Runtime::NotFound => e
          # NotFound is a VERDICT, not noise. An attribute's type is a reference to
          # its value object, so "no ValueObject with id …" IS the rule `attributes
          # must use value-object types` refusing.
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::UnknownVerb
          nil
        end

        def send_to(verb, label, **payload)
          offer(label) { @runtime.dispatch(verb, **args(payload)) }
        end

        def judge!
          declare_node("Bluebook", @bluebook, nil, 0)
          detail_node("Bluebook", @bluebook, nil, 0)
        end

        # DECLARED BEFORE DETAILED, for every set of siblings.
        #
        # A node used to be offered whole — declared, then its lists, then its
        # children — one sibling at a time. Which means an aggregate's attributes
        # were offered before its later siblings existed, and an attribute that
        # POINTS AT another aggregate could only resolve if that aggregate happened
        # to be declared earlier in the file. Banking survives on luck: Customer is
        # written above Account.
        #
        # So siblings are declared in one pass and detailed in a second. It is the
        # same ordering the walk already used one level down — value objects before
        # the attributes that name them — lifted to the level above, and it is what
        # lets a reference be a REFERENCE rather than a string nobody can check.
        def declare_node(category, node, parent_id, index, extra = {})
          plan = @plan.category(category)
          return unless plan

          declare(plan, category, node, identify(category, parent_id, node, index), parent_id, index, extra)
        end

        def detail_node(category, node, parent_id, index, _extra = {})
          plan = @plan.category(category)
          return unless plan

          id           = identify(category, parent_id, node, index)
          eager, later = children_of(category).partition { |child| eager?(category, child) }

          eager.each { |child| walk_all(child, node, id) }
          setters(plan, category, node, id)
          appends(plan, category, node, id)
          later.each { |child| walk_all(child, node, id) }
          within_entity(category, node, id, parent_id)
          sealers(plan, category, id)
        end

        def walk_all(category, node, parent_id, extra = {})
          reader = collection_reader(category)
          return unless node.respond_to?(reader)

          children = Array(node.public_send(reader))
          children.each_with_index { |child, index| declare_node(category, child, parent_id, index, extra) }
          children.each_with_index { |child, index| detail_node(category, child, parent_id, index, extra) }
        end

        # A piece's commands and queries, addressed under the PIECE so two commands
        # of the same name on an aggregate and on one of its entities cannot collide,
        # while `aggregate_id` still names the aggregate the reference resolves
        # against and `entity_id` says which piece declared it.
        def within_entity(category, node, id, aggregate_id)
          return unless category == "Entity"

          WITHIN_ENTITY.each do |child|
            walk_all(child, node, id, aggregate_id: v(aggregate_id), entity_id: v(id))
          end
        end

        # WHERE IT SITS AMONG ITS SIBLINGS IS A FACT ABOUT THE WALK, not about the
        # node : a command does not know it is the third command on its aggregate.
        # The walk knows, so the walk supplies it, and every other field still
        # comes from the node. Declaration order used to survive only because the
        # meta store happened to iterate in insertion order — an accident that an
        # ask ordered any other way would have taken away, and Reconstruction is
        # the one reader that must have the SOURCE'S order rather than a stable one.
        POSITION = "position"

        def declare(plan, category, node, id, parent_id, index, extra = {})
          return unless plan.declare

          payload = { id: id }
          payload[plan.parent_key.to_sym] = v(parent_id) if plan.parent_key
          plan.fields.each do |field|
            payload[field.to_sym] = if field == POSITION
                                      v(index)
                                    else
                                      v(field_value(category, node, field.to_sym, parent_id))
                                    end
          end

          send_to("Meta::#{category}.#{plan.declare}", id, **payload.merge(extra))
        end

        # A setter whose every source is absent is not dispatched. An aggregate
        # with no lifecycle has no Lifecycle to offer, and a creating command has
        # no root to act on — offering either as "" would make a rule refuse a
        # bluebook that is perfectly well formed.
        def setters(plan, category, node, id)
          plan.setters.each do |setter|
            payload = setter.targets.to_h do |target, argument|
              [argument.to_sym, v(setter_value(category, node, target))]
            end
            next if payload.values.all?(&:nil?)

            send_to("Meta::#{category}.#{setter.verb}", id, id: id, **payload)
          end
        end

        def appends(plan, category, node, id)
          plan.appends.each do |list_name, append|
            rows_for(category, list_name, node).each_with_index do |row, index|
              chosen = append_for(category, list_name, append, row, node)
              payload = chosen.map.to_h do |field, argument|
                [argument.to_sym, v(cell(category, list_name, row, field, id, chosen))]
              end

              send_to("Meta::#{category}.#{chosen.verb}", "#{id}##{list_name}[#{index}]",
                      id: id, **payload)
            end
          end
        end

        def sealers(plan, category, id)
          plan.sealers.each { |verb| send_to("Meta::#{category}.#{verb}", id, id: id) }
        end

        # An aggregate's attribute names its value object by TYPE, and the language
        # models that as a reference — so the type is offered as the value object's
        # own id. This is the rule "attributes must use value-object types",
        # enforced by reference resolution rather than by a predicate.
        # An attribute's type is offered as the ID OF THE THING IT NAMES, so the
        # language resolves it as a reference and "the type is declared" costs no
        # predicate. Three kinds, three ids: a value object and an entity both hang
        # off this aggregate, so they share its prefix; another aggregate's head
        # hangs off the chapter.
        def cell(category, list_name, row, field, id, append)
          value = row_value(row, field)
          # A default keeps its TYPE by being written as a literal — 0.0 rather than
          # "0.0" — because the language holds it as text and text alone forgets.
          return encode_literal(value) if field == :default
          return value unless field == :type
          # A REFERENCE names another head WHEREVER it is written — on a head, on
          # a command, on a piece, on an ask — so it is offered as that head's
          # id in all four. Only the head's own attributes additionally qualify
          # an ordinary type into a value object's id ; a command argument's
          # type is text and stays text.
          return points_at(row, id) if append.verb == "Reference"
          return value unless "#{category}.#{list_name}" == "Aggregate.attributes"

          "#{id}.#{value}"
        end

        # Which verb an attribute row belongs to. The plan cannot decide this — all
        # three append to the same list — and what tells them apart is the row:
        #
        #   Attribute  its type names a value object of this aggregate
        #   Reference  its type is Reference<X>, another aggregate's head
        #   Holds      its type names an entity this aggregate declares
        #
        # NOTHING IS SKIPPED any more. Reference and Holds did not exist, so the
        # walk dropped both kinds and the meta-domain silently did not contain
        # Account#customer_id or Account#ledger.
        # Each alternate carries its OWN map, read from the language. Borrowing the
        # primary's map dispatched `type:` where Reference declares `points_at:`,
        # and the payload gate caught it — which is the gate paying for itself.
        # `reference_to` can be written in FOUR places — on a head, a command, a
        # piece, an ask — and each keeps its own list of attributes, so each
        # needs the Reference alternate. Only a head can hold a piece, so Holds
        # stays where it was.
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

        # Only a HEAD declares pieces, and now that every attribute list reaches
        # this, the node may be a command, a piece or an ask — none of which
        # answer `entities` at all.
        def entity_row?(row, node)
          return false unless node.respond_to?(:entities)

          Array(node.entities).any? { |entity| entity.hecks_name == row.type.to_s }
        end

        def identify(category, parent_id, node, index)
          case category
          when "Bluebook"  then declared_name(node)
          when "Aggregate" then "#{parent_id}::#{declared_name(node)}"
          when "Member", "Handler", "Dispatch" then "#{parent_id}##{index}"
          else "#{parent_id}.#{declared_name(node)}"
          end
        end

        def children_of(category)
          @plan.names.select { |name| @plan.category(name).parent == category }
        end

        def eager?(category, child) = Array(EAGER_CHILDREN[category]).include?(child)

        # Command -> commands, ValueObject -> value_objects, Query -> queries.
        # Convention, not a table : the IR names a collection after what it holds.
        # The pluraliser lives in Naming because there used to be two of them and
        # one was wrong — see Naming.plural.
        def collection_reader(category) = Naming.plural(Naming.snake(category))
      end
    end
  end
end
