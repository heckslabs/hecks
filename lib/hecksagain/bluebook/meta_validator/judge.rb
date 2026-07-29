module Hecksagain
  module Bluebook
    module MetaValidator
      # Offers every declaration in a built bluebook to the meta-domain.
      #
      # Coverage is the whole point. A rule declared in the language but never
      # DISPATCHED here cannot fire — five rules sat in that state after the
      # first pass, declared and unreachable, which is the same defect this
      # project keeps finding one level down. If the language declares a rule
      # about queries, this has to offer it queries.
      #
      # Only the DISPATCH half of the round trip lives here. Reconstruction is
      # the experiment's business ; judging does not need it.
      class Judge
        attr_reader :refusals

        def initialize(bluebook)
          @bluebook = bluebook
          @refusals = []
          @runtime  = MetaValidator.fresh_runtime
          judge!
        end

        private

        # ABSENT is not EMPTY. The builders' rules read "if you declare it,
        # declare something" — a description never given is legal. Passing ""
        # for a nil turns every one of them into "you must declare it".
        def v(text) = text.nil? ? nil : { value: text.to_s }

        def args(pairs) = pairs.reject { |_, value| value.nil? }

        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation,
               Runtime::TypeMismatch, Runtime::NotFound => e
          # NotFound is a VERDICT now, not noise. An attribute's type is a
          # reference to its value object, so "no Shape with id …" IS the rule
          # `attributes must use value-object types` refusing. Swallowing it
          # hid that rule completely the first time this was wired.
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::UnknownVerb
          # a category the language does not describe yet is not a defect in
          # the bluebook being judged
          nil
        end

        def send_to(verb, label, **payload)
          offer(label) { @runtime.dispatch(verb, **args(payload)) }
        end

        def judge!
          chapter = @bluebook.name
          send_to("Meta::Chapter.Declare", chapter, name: v(chapter),
                  vision: v(@bluebook.vision), classification: v(@bluebook.classification))
          @bluebook.aggregates.each { |aggregate| judge_aggregate(chapter, aggregate) }
          Array(@bluebook.read_models).each      { |model|  judge_projection(chapter, model) }
          Array(@bluebook.policies).each         { |policy| judge_reaction(chapter, policy) }
          Array(@bluebook.process_managers).each { |saga|   judge_saga(chapter, saga) }
        end

        def judge_reaction(chapter, policy)
          id = "#{chapter}.#{policy.name}"
          send_to("Meta::Reaction.Declare", id, id: id, chapter_id: v(chapter),
                  name: v(policy.name), watches: v(policy.on_event),
                  fires: v(policy.trigger_command), reaches: v(policy.target_domain))
        end

        def judge_saga(chapter, saga)
          id = "#{chapter}.#{saga.name}"
          send_to("Meta::Saga.Declare", id, id: id, chapter_id: v(chapter),
                  name: v(saga.name), correlate: v(saga.correlates_by),
                  starts: v(saga.starts_on), ends: v(saga.ends_on))

          Array(saga.states).each do |state|
            send_to("Meta::Saga.State", id, id: id, name: v(state))
          end
        end

        def judge_aggregate(chapter, aggregate)
          root = "#{chapter}::#{aggregate.name}"
          send_to("Meta::Root.Declare", root, id: root, chapter_id: v(chapter),
                  name: v(aggregate.name), description: v(aggregate.description),
                  identity: v(aggregate.identified_by))

          # shapes FIRST : an attribute's type is a reference to its value
          # object, so the value object has to exist before the attribute names it
          Array(aggregate.entities).each { |piece| judge_piece(root, aggregate, piece) }
          aggregate.value_objects.each { |shape| judge_shape(root, aggregate, shape) }

          aggregate.attributes.each do |attribute|
            # a REFERENCE is not a value object. `Reference<Customer>` names
            # another aggregate head, so it neither has nor needs a Shape — the
            # language does not model reference-typed attributes yet, and
            # judging them as value objects is what made the language fail its
            # own rules the moment the type became a reference.
            next if attribute.reference?
            # a list of ENTITIES names a Piece, not a Shape. The builder's rule
            # admitted both ; the reference only reaches Shapes, so entity-typed
            # lists are judged by the Piece declarations instead.
            next if aggregate.entities.any? { |entity| entity.name == attribute.type.to_s }

            send_to("Meta::Root.Attribute", "#{root}##{attribute.name}", id: root,
                    name: v(attribute.name), type: v("#{root}.#{attribute.type}"),
                    list: v(attribute.list?))
          end
          Array(aggregate.queries).each  { |ask|   judge_ask(root, aggregate, ask) }
          aggregate.commands.each        { |verb|  judge_command(root, aggregate, verb) }
        end

        def judge_piece(root, _aggregate, piece)
          id = "#{root}.#{piece.name}"
          send_to("Meta::Piece.Declare", id, id: id, root_id: v(root), owner: v(root),
                  name: v(piece.name), description: v(piece.description),
                  identity: v(piece.identified_by))
        end

        def judge_shape(root, _aggregate, shape)
          id = "#{root}.#{shape.name}"
          send_to("Meta::Shape.Declare", id, id: id, root_id: v(root), name: v(shape.name))

          shape.invariants.each do |invariant|
            send_to("Meta::Shape.Assert", id, id: id,
                    description: v(invariant.description), canonical: v(invariant.canonical))
          end

          # only when a closed set was DECLARED — an empty one is the defect
          if shape.respond_to?(:closed_set?) && shape.closed_set?
            send_to("Meta::Shape.Close", id, id: id, rows: { value: Array(shape.members).size })
          end

          Array(shape.members).each_with_index do |row, index|
            member = "#{id}##{index}"
            send_to("Meta::Member.Declare", member, id: member, shape_id: v(id), shape: v(id))
            row.to_h.each do |key, value|
              send_to("Meta::Member.Pair", member, id: member, key: v(key), value: v(value))
            end
          end
        end

        def judge_ask(root, _aggregate, ask)
          id = "#{root}.#{ask.name}"
          send_to("Meta::Ask.Declare", id, id: id, root_id: v(root),
                  name: v(ask.name), purpose: v(ask.description))

          Array(ask.attributes).each do |attribute|
            send_to("Meta::Ask.Argument", id, id: id, name: v(attribute.name),
                    type: v(attribute.type), list: v(attribute.list?), default: v(attribute.default))
          end
        end

        def judge_projection(chapter, model)
          id = "#{chapter}.#{model.name}"
          send_to("Meta::Projection.Declare", id, id: id, chapter_id: v(chapter),
                  name: v(model.name), purpose: v(model.description),
                  query_name: v(model.query_name), ref_name: v(model.reference_name),
                  ref_target: v(model.reference_target))

          Array(model.aggregate_heads).each do |head|
            send_to("Meta::Projection.Gather", id, id: id, aggregate: v(head[:aggregate]),
                    as: v(head[:as]), many: v(head[:many]))
          end
        end

        def judge_command(root, _aggregate, command)
          id = "#{root}.#{command.name}"
          send_to("Meta::Verb.Declare", id, id: id, root_id: v(root),
                  name: v(command.name), role: v(command.role), goal: v(command.goal))

          command.givens.each do |given|
            send_to("Meta::Verb.Rule", id, id: id,
                    description: v(given.description), canonical: v(given.canonical))
          end

          command.mutations.each do |mutation|
            send_to("Meta::Verb.Change", "#{id}!#{mutation.target}", id: id,
                    target: v(mutation.target), op: v(mutation.op),
                    field: v(""), kind: v("argument"), source: v(""))
          end

          # dispatched even when absent, so "a command names what it acts on"
          # is reachable — a rule only offered valid input can never refuse
          send_to("Meta::Verb.ActsOn", id, id: id, root: v(command.references)) if command.references

          Array(command.emits).each do |event|
            send_to("Meta::Verb.Announce", id, id: id, announces: v(event))
          end
        end
      end
    end
  end
end
