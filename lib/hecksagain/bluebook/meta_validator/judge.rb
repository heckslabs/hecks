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

        # Children offered BEFORE the parent's own lists. An attribute's type is a
        # reference to the value object it names, so the value objects have to
        # exist before any attribute names one — and an entity-typed list names a
        # Piece, which the attribute walk needs in order to skip it.
        EAGER_CHILDREN = { "Aggregate" => %w[Entity ValueObject] }.freeze

        attr_reader :refusals

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

        def judge! = walk("Bluebook", @bluebook, nil, 0)

        # One node, offered whole: itself, then what it contains.
        def walk(category, node, parent_id, index)
          plan = @plan.category(category)
          return unless plan

          id           = identify(category, parent_id, node, index)
          eager, later = children_of(category).partition { |child| eager?(category, child) }

          declare(plan, category, node, id, parent_id)
          eager.each { |child| walk_all(child, node, id) }
          setters(plan, category, node, id)
          appends(plan, category, node, id)
          later.each { |child| walk_all(child, node, id) }
          sealers(plan, category, id)
        end

        def walk_all(category, node, parent_id)
          reader = collection_reader(category)
          return unless node.respond_to?(reader)

          Array(node.public_send(reader)).each_with_index do |child, index|
            walk(category, child, parent_id, index)
          end
        end

        def declare(plan, category, node, id, parent_id)
          return unless plan.declare

          payload = { id: id }
          payload[plan.parent_key.to_sym] = v(parent_id) if plan.parent_key
          plan.fields.each do |field|
            payload[field.to_sym] = v(field_value(category, node, field.to_sym, parent_id))
          end

          send_to("Meta::#{category}.#{plan.declare}", id, **payload)
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
              next if skip?(category, list_name, row, node)

              chosen  = append_for(category, list_name, append, row)
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
        def cell(category, list_name, row, field, id, append)
          value = row_value(row, field)
          # Only an ordinary attribute's type is requalified into a value object's
          # id. A reference's type is `Reference<Customer>` and must arrive as it
          # is — requalifying it would ask the value objects for something that was
          # never one.
          return value unless field == :type && "#{category}.#{list_name}" == "Aggregate.attributes"
          return value if append.verb == "Reference"

          "#{id}.#{value}"
        end

        # A REFERENCE is not a value object : `Reference<Customer>` names another
        # aggregate head, so it cannot go through Attribute, whose type resolves
        # against the value objects. It has its OWN verb, and offering it there is
        # what stopped the meta-domain silently not holding Account#customer_id.
        #
        # A list of ENTITIES still has no verb — its type names a Piece, which is
        # neither a value object nor a reference — so those attributes remain
        # unoffered and the way back remains lossy for them. Named rather than
        # excused: the fix is an Aggregate verb for an entity-typed attribute, the
        # same shape as this one.
        def skip?(category, list_name, row, node)
          return false unless "#{category}.#{list_name}" == "Aggregate.attributes"

          Array(node.entities).any? { |entity| entity.name == row.type.to_s }
        end

        # Which verb an attribute row belongs to. The plan cannot decide this — both
        # verbs append to the same list, and what tells them apart is the row.
        def append_for(category, list_name, append, row)
          return append unless "#{category}.#{list_name}" == "Aggregate.attributes"
          return append unless row.respond_to?(:reference?) && row.reference?

          Plan::Append.new(verb: "Reference", map: append.map)
        end

        def identify(category, parent_id, node, index)
          case category
          when "Bluebook"  then node.name
          when "Aggregate" then "#{parent_id}::#{node.name}"
          when "Member", "Handler", "Dispatch" then "#{parent_id}##{index}"
          else "#{parent_id}.#{node.name}"
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
