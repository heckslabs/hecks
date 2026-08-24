module Hecks
  module Bluebook
    class Assembly
      # One head, built from its declaration.
      #
      # The fields come from the contract like every other construct's. What is here
      # is the part no field table can say: which construct holds which, and how a
      # head's references become able to resolve.
      #
      # It DECIDES NOTHING. Whether a declaration is admissible was settled on the
      # way in, by the language.
      class AggregateAssembly
        def initialize(row)
          @row = row
        end

        def aggregate
          shapes   = Array(@row[:value_objects]).map { |shape| value_object(shape) }
          commands = Array(@row[:commands]).map { |verb| Build.call("Command", verb) }
          entities = Array(@row[:entities]).map { |piece| entity(piece) }
          asks     = Array(@row[:queries]).map { |ask| Build.call("Query", ask) }

          fields = Array(@row[:attributes]).map { |field| Marks.attribute(field) }

          ir = Build.call(
            "Aggregate", @row,
            value_objects:     shapes,
            commands:          commands,
            entities:          entities,
            queries:           asks,
            lifecycle:         lifecycle_of(@row),
            # A policy declared inside a head is HOISTED onto the chapter by the
            # builder, and `Aggregate#to_h` never carried it — so the language does
            # not record which head a chapter-level policy was written in. The
            # chapter holds them all, which is what `PolicyInterpreter` reads.
            policies:          [],
            reference_targets: reference_targets(fields)
          )

          stamp_references(ir)
          ir
        end

        private

        # What this head points at with an aggregate-level `reference_to`. NOT the
        # self-references its verbs carry — the first version read
        # `commands.filter_map(&:references)` and gave Pizza two targets of "Pizza",
        # its own verbs pointing at itself, where the builder recorded none. An
        # aggregate-level `reference_to X` leaves a reference ATTRIBUTE behind, so
        # the attributes are where the answer is.
        def reference_targets(fields)
          fields.select(&:reference?).map { |field| field.type.target_name }
        end

        def value_object(row)
          Build.call("ValueObject", row)
        end

        # S17, ADR 0026 — RECURSES. "That is what `entity` is for, and
        # `entity` is declared by the language and used zero times in it"
        # — Dispatch, inside Handler, is the first use, so `row[:entities]`
        # is built the same way `row` itself was reached: through this
        # same method, one level deeper each time. Nothing here assumes
        # it stops at one level of nesting.
        def entity(row)
          Build.call(
            "Entity", row,
            commands:  Array(row[:commands]).map { |verb| Build.call("Command", verb) },
            queries:   Array(row[:queries]).map { |ask| Build.call("Query", ask) },
            entities:  Array(row[:entities]).map { |piece| entity(piece) },
            lifecycle: lifecycle_of(row)
          )
        end

        # Every reference learns which head declares it, so it can reach the chapter
        # and resolve. Deliberately across every list that can carry one — a
        # reference the walk misses resolves to nil, and a nil target is SKIPPED
        # rather than refused, so the guarantee would go quiet instead of red.
        def stamp_references(ir)
          lists = [ir.attributes, *ir.commands.map(&:attributes), *ir.queries.map(&:attributes)]
          entity_reference_lists(ir.entities, lists)

          lists.flatten.select(&:reference?).each { |field| field.type.declared_in = ir }
        end

        # S17, ADR 0026 — walks NESTED entities too (Dispatch, inside
        # Handler), not only an aggregate's own direct ones.
        def entity_reference_lists(entities, lists)
          entities.each do |piece|
            lists << piece.attributes
            lists.concat(piece.commands.map(&:attributes))
            lists.concat(piece.queries.map(&:attributes))
            entity_reference_lists(piece.entities, lists)
          end
        end

        # THREE LANGUAGE FIELDS, ONE IR OBJECT. `state_field`, `state_start` and
        # `transitions` are separate declarations; the IR keeps one Lifecycle. The
        # contract names them derived, and this is what derives them.
        def lifecycle_of(row)
          declared = row[:lifecycle]
          return nil unless declared

          Lifecycle.new(
            field:       declared[:field],
            default:     declared[:default],
            transitions: transitions(Array(declared[:transitions]))
          )
        end

        # A lifecycle holds [command, StateTransition] pairs and `to_h` expands one
        # pair whose `from` is a list into several rows. Grouped back by command AND
        # TARGET, because one declared pair has exactly one target and may have many
        # froms — grouping by command alone would fuse two declarations that move the
        # same verb to different states.
        def transitions(rows)
          rows.group_by { |move| [move[:command], move[:to_state]] }
              .map do |(command, target), moves|
                froms = moves.filter_map { |move| move[:from_state] }
                [command.to_s, StateTransition.new(target: target, from: from_of(froms))]
              end
        end

        def from_of(froms)
          return nil         if froms.empty?
          return froms.first if froms.size == 1

          froms
        end
      end
    end
  end
end
